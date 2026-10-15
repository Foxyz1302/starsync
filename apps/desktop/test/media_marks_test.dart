import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/session_media.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/playback/media_marks.dart';

Duration s(num secs) => Duration(milliseconds: (secs * 1000).round());
Duration m(int min, [int sec = 0]) => Duration(minutes: min, seconds: sec);

/// OP 0:30-2:00, Part A, ED 20:00-21:30, Part B; 24:00 long.
final chapters = chaptersFromStarts([
  ('Prologue', Duration.zero),
  ('OP', m(0, 30)),
  ('Part A', m(2)),
  ('ED', m(20)),
  ('Part B', m(21, 30)),
], m(24));

void main() {
  group('chapter-list', () {
    test('parses mpv JSON, ends from the next start and the duration', () {
      final c = parseChapterList(
          '[{"title":"OP","time":30.0},{"title":"Part A","time":120.5},{"time":1200}]', m(24));
      expect(c, [
        MediaChapter(index: 0, title: 'OP', start: s(30), end: s(120.5)),
        MediaChapter(index: 1, title: 'Part A', start: s(120.5), end: m(20)),
        MediaChapter(index: 2, title: '', start: m(20), end: m(24)),
      ]);
    });

    test('unknown duration: the last chapter ends where it starts', () {
      final c = parseChapterList('[{"title":"A","time":0},{"title":"B","time":10}]', Duration.zero);
      expect(c.last.end, s(10));
    });

    test('garbage gives none', () {
      expect(parseChapterList('', m(1)), isEmpty);
      expect(parseChapterList('{"a":1}', m(1)), isEmpty);
      expect(parseChapterList('[{"title":"x"}]', m(1)), isEmpty);
    });
  });

  group('track-list', () {
    test('audio and subtitles with flags and selection; video left out', () {
      final t = parseTrackList('''[
        {"id":1,"type":"video","codec":"h264","selected":true},
        {"id":1,"type":"audio","lang":"jpn","codec":"eac3","demux-channel-count":2,"default":true,"selected":true},
        {"id":2,"type":"audio","lang":"eng","title":"Dub","codec":"aac","demux-channel-count":6},
        {"id":1,"type":"sub","lang":"eng","title":"Signs","codec":"ass","forced":true},
        {"id":2,"type":"sub","codec":"subrip","external":true,"selected":true}
      ]''');
      expect(t.length, 4);
      expect(t[0], const MpvTrack(
          id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2,
          isDefault: true, selected: true));
      expect(t[2].isForced, isTrue);
      expect(t[3].isExternal && t[3].selected, isTrue);
      expect(t.map((x) => x.label), [
        'Japanese · E-AC3 2.0',
        'English · AAC 5.1 · Dub',
        'English · ASS · Signs · Forced',
        'Track 2 · SRT',
      ]);
    });
  });

  group('opening / ending', () {
    test('from Jellyfin segments first', () {
      final seg = [
        MediaSegment(kind: JellyfinSegmentType.recap, start: Duration.zero, end: s(20)),
        MediaSegment(kind: JellyfinSegmentType.intro, start: s(40), end: s(130)),
        MediaSegment(kind: JellyfinSegmentType.outro, start: m(21), end: m(22, 30)),
      ];
      expect(openingRange(seg, chapters), SkipRange(s(40), s(130), SkipSource.segment));
      expect(endingRange(seg, chapters), SkipRange(m(21), m(22, 30), SkipSource.segment));
    });

    test('else from chapter titles', () {
      expect(openingRange(const [], chapters), SkipRange(s(30), m(2), SkipSource.chapter, title: 'OP'));
      expect(endingRange(const [], chapters), SkipRange(m(20), m(21, 30), SkipSource.chapter, title: 'ED'));
    });

    test('an empty segment range falls back to chapters', () {
      final seg = [MediaSegment(kind: JellyfinSegmentType.intro, start: s(10), end: s(10))];
      expect(openingRange(seg, chapters)!.source, SkipSource.chapter);
    });

    test('title variants: whole words, any case, numbered', () {
      for (final t in ['OP', 'op', 'OP1', 'OP 2', 'Opening', 'Opening Song', 'Intro', 'INTRO']) {
        expect(isOpeningTitle(t), isTrue, reason: t);
      }
      for (final t in ['Opportunity', 'Operation', 'Introduction', 'Part A', 'Prologue', 'Stop', '']) {
        expect(isOpeningTitle(t), isFalse, reason: t);
      }
      for (final t in ['ED', 'ed', 'ED2', 'Ending', 'Ending Theme', 'Credits', 'End Credits', 'Outro']) {
        expect(isEndingTitle(t), isTrue, reason: t);
      }
      for (final t in ['Edge', 'Edited', 'Endings?', 'Part B', 'Preview', 'Red']) {
        expect(isEndingTitle(t), isFalse, reason: t);
      }
    });

    test('none: no segments and no matching chapter titles', () {
      final plain = chaptersFromStarts([('Part A', Duration.zero), ('Part B', m(10))], m(24));
      expect(openingRange(const [], plain), isNull);
      expect(endingRange(const [], plain), isNull);
      expect(openingRange(const [], const []), isNull);
    });
  });

  group('skip offers', () {
    final op = SkipRange(s(30), m(2), SkipSource.chapter);
    final ed = SkipRange(m(20), m(21, 30), SkipSource.chapter);
    SkipOffer? at(Duration p,
            {SkipRange? opening, SkipRange? ending, Duration? duration, bool chaptered = false}) =>
        skipOfferAt(
            position: p,
            duration: duration ?? m(24),
            opening: opening,
            ending: ending,
            chaptered: chaptered);

    test('Skip OP inside the opening, to its end', () {
      expect(at(s(29), opening: op, ending: ed), isNull);
      expect(at(s(30), opening: op, ending: ed), SkipOffer(SkipKind.opening, m(2)));
      expect(at(s(118), opening: op, ending: ed), SkipOffer(SkipKind.opening, m(2)));
      // Last second: nothing left to skip.
      expect(at(s(119.5), opening: op, ending: ed), isNull);
      expect(at(m(5), opening: op, ending: ed), isNull);
    });

    test('Skip ED to the ending end only', () {
      expect(at(m(20), opening: op, ending: ed), SkipOffer(SkipKind.ending, m(21, 30)));
      expect(at(m(21), opening: op, ending: ed), SkipOffer(SkipKind.ending, m(21, 30)));
      expect(at(m(21, 30), opening: op, ending: ed), isNull);
      // Known ending without an opening: the fallback applies early on.
      expect(at(m(20, 10), ending: ed), SkipOffer(SkipKind.ending, m(21, 30)));
    });

    test('1:30 fallback: no opening, over 20 min, first 6 min only', () {
      expect(at(Duration.zero), SkipOffer(SkipKind.fixed, s(90)));
      expect(at(m(1)), SkipOffer(SkipKind.fixed, m(2, 30)));
      expect(at(m(5, 59)), SkipOffer(SkipKind.fixed, m(7, 29)));
      expect(at(m(6)), isNull);
      expect(at(m(1), duration: m(20)), isNull, reason: 'exactly 20 min is not over');
      expect(at(m(1), duration: m(12)), isNull);
      expect(at(m(1), ending: ed), SkipOffer(SkipKind.fixed, m(2, 30)));
      // An opening known (but not playing) means no fallback.
      expect(at(m(3), opening: op), isNull);
      // Chapters without an OP chapter: no opening on purpose.
      expect(at(m(1), chaptered: true), isNull);
      expect(at(m(20, 10), ending: ed, chaptered: true), SkipOffer(SkipKind.ending, m(21, 30)));
    });
  });

  group('next episode prompt', () {
    test('at the ED start when known, else the last two minutes', () {
      expect(nextPromptStart(null, m(24), endingStart: m(20)), m(20));
      expect(nextPromptStart(null, m(24)), m(22));
      expect(nextPromptStart(null, m(24), endingStart: null), m(22));
      // Nonsense ending starts fall back.
      expect(nextPromptStart(null, m(24), endingStart: m(25)), m(22));
      expect(nextPromptStart(null, m(24), endingStart: Duration.zero), m(22));
      expect(nextPromptStart(null, s(90)), Duration.zero);
    });
  });

  group('chapter steps (PgUp / PgDn)', () {
    test('current chapter and forward steps', () {
      expect(chapterIndexAt(chapters, s(45)), 1);
      expect(chapterIndexAt(chapters, m(23)), 4);
      expect(chapterStepTarget(chapters, s(45), 1), m(2));
      expect(chapterStepTarget(chapters, m(21), 1), m(21, 30));
      expect(chapterStepTarget(chapters, m(22), 1), isNull, reason: 'no chapter after the last');
    });

    test('back: current start, or the previous one near a start (mpv)', () {
      expect(chapterStepTarget(chapters, m(10), -1), m(2));
      expect(chapterStepTarget(chapters, m(2, 3), -1), s(30));
      expect(chapterStepTarget(chapters, s(2), -1), Duration.zero);
      expect(chapterStepTarget(const [], m(1), 1), isNull);
    });

    test('before the first chapter forward goes to it', () {
      final late = chaptersFromStarts([('A', m(1)), ('B', m(5))], m(10));
      expect(chapterIndexAt(late, s(10)), isNull);
      expect(chapterStepTarget(late, s(10), 1), m(1));
      expect(chapterStepTarget(late, s(10), -1), isNull);
    });
  });

  test('clock format', () {
    expect(formatClock(s(65)), '1:05');
    expect(formatClock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  test('menu labels: language names, codecs, layouts', () {
    expect(languageName('jpn'), 'Japanese');
    expect(languageName('xyz'), 'XYZ');
    expect(languageName(null), isNull);
    expect(codecName('hdmv_pgs_subtitle'), 'PGS');
    expect(codecName('pcm_s16le'), 'PCM');
    expect(channelLayoutName(8), '7.1');
    expect(channelLayoutName(4), '4ch');
  });
}
