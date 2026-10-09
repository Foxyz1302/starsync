import 'sfx.dart';
import 'synth.dart';

// The app's sound set, all in D major pentatonic so any two that overlap
// still agree. Rising = someone arrives / gets ready, falling = leaves /
// unready; bells for people, soft sines for the player, plucks for ticks.
// Everything is quiet (-16 dBFS peaks or lower) and short.

// Pitches, in semitones from A4.
const _d4 = -7, _e4 = -5, _a4 = 0;
const _d5 = 5, _e5 = 7, _fs5 = 9, _a5 = 12, _b5 = 14;
const _d6 = 17, _e6 = 19, _fs6 = 21, _a6 = 24;

double _p(int s) => semi(s);

/// The ready chime's second note climbs with how many are ready (1st, 2nd…).
const _readyLadder = [_fs5, _a5, _b5, _d6, _e6, _fs6];

SoundSpec readySound(int readyIndex) {
  final top = _readyLadder[(readyIndex - 1).clamp(0, _readyLadder.length - 1)];
  return SoundSpec([
    Note(0, _p(_d5), 0.35, gain: 0.8),
    Note(0.075, _p(top), 0.55),
  ]);
}

SoundSpec soundFor(SfxKind kind, {int readyIndex = 1}) => switch (kind) {
      SfxKind.ready => readySound(readyIndex),
      SfxKind.unready => SoundSpec([
          Note(0, _p(_a5), 0.3, gain: 0.8),
          Note(0.08, _p(_e5), 0.45, gain: 0.7),
        ], cutoff: 4200, peakDb: -19),
      SfxKind.forceReady => SoundSpec([
          Note(0, _p(_d5), 0.35, gain: 0.7),
          Note(0.06, _p(_fs5), 0.35, gain: 0.8),
          Note(0.12, _p(_a5), 0.6),
        ]),
      SfxKind.forceUnready => SoundSpec([
          Note(0, _p(_a5), 0.3, gain: 0.8),
          Note(0.06, _p(_fs5), 0.3, gain: 0.7),
          Note(0.12, _p(_d5), 0.5, gain: 0.7),
        ], cutoff: 4200, peakDb: -19),
      SfxKind.forcePlay => SoundSpec([
          Note(0, _p(_d5), 0.7, gain: 0.6, voice: Voice.soft),
          Note(0, _p(_a5), 0.7, gain: 0.5, voice: Voice.soft),
          Note(0.12, _p(_d6), 0.8),
        ]),
      SfxKind.forceHold => SoundSpec([
          Note(0, _p(_a4), 0.35, voice: Voice.soft),
          Note(0.1, _p(_d4), 0.55, voice: Voice.soft),
        ], cutoff: 3000, peakDb: -18),
      SfxKind.kick => SoundSpec([
          Note(0, _p(_e4), 0.4, voice: Voice.soft, to: _p(_d4 - 2)),
          Note(0.14, _p(_d4 - 5), 0.6, voice: Voice.soft, gain: 0.8),
        ], cutoff: 1800, peakDb: -19),
      SfxKind.join => SoundSpec([
          Note(0, _p(_d5), 0.3, gain: 0.7),
          Note(0.07, _p(_e5), 0.3, gain: 0.75),
          Note(0.14, _p(_a5), 0.6),
        ]),
      SfxKind.leave => SoundSpec([
          Note(0, _p(_a5), 0.28, gain: 0.8),
          Note(0.08, _p(_e5), 0.28, gain: 0.7),
          Note(0.16, _p(_d5), 0.5, gain: 0.6),
        ], cutoff: 3800, peakDb: -20),
      SfxKind.stale => SoundSpec([
          Note(0, _p(_fs5), 0.6, voice: Voice.soft, wobble: 0.25),
        ], cutoff: 3500, peakDb: -21),
      SfxKind.swap => SoundSpec([
          Note(0, _p(_d5), 0.6, voice: Voice.soft, gain: 0.6),
          Note(0.05, _p(_a5), 0.3, gain: 0.5),
          Note(0.1, _p(_d6), 0.3, gain: 0.5),
          Note(0.15, _p(_fs6), 0.5, gain: 0.45),
        ], cutoff: 6000, peakDb: -18),
      SfxKind.seek => const SoundSpec([
          Note(0, 987.77, 0.06, voice: Voice.pluck),
        ], cutoff: 3500, peakDb: -26, room: 0),
      SfxKind.pause => SoundSpec([
          Note(0, _p(_a4), 0.28, voice: Voice.soft, to: _p(_e4)),
        ], cutoff: 3000, peakDb: -21, room: 0.08),
      SfxKind.resume => SoundSpec([
          Note(0, _p(_a4), 0.28, voice: Voice.soft, to: _p(_d5)),
        ], cutoff: 3500, peakDb: -21, room: 0.08),
      SfxKind.chat => SoundSpec([
          Note(0, _p(_b5), 0.18, gain: 0.7),
          Note(0.055, _p(_e6), 0.3),
        ], cutoff: 5500, peakDb: -19, room: 0.1),
      SfxKind.warn => SoundSpec([
          Note(0, _p(_fs5), 0.25, voice: Voice.soft),
          Note(0.22, _p(_fs5), 0.25, voice: Voice.soft, gain: 0.85),
          Note(0.44, _p(_d5), 0.45, voice: Voice.soft, gain: 0.8),
        ], cutoff: 3800, peakDb: -18),
    };

/// Sounds the app has no event for yet (proposals, shown in the demo).
enum ExtraSound { start, finished, lost, back, image, mention }

SoundSpec extraSound(ExtraSound s) => switch (s) {
      ExtraSound.start => SoundSpec([
          Note(0, _p(_d5), 0.9, voice: Voice.soft, gain: 0.5),
          Note(0.04, _p(_fs5), 0.9, voice: Voice.soft, gain: 0.45),
          Note(0.08, _p(_a5), 0.9, voice: Voice.soft, gain: 0.45),
          Note(0.12, _p(_d6), 0.9, gain: 0.6),
        ], cutoff: 5000, peakDb: -18, room: 0.2),
      ExtraSound.finished => SoundSpec([
          Note(0, _p(_a5), 0.5, gain: 0.8),
          Note(0.16, _p(_fs5), 0.5, gain: 0.75),
          Note(0.32, _p(_d5), 1.1, gain: 0.8),
          Note(0.32, _p(_a4), 1.1, voice: Voice.soft, gain: 0.4),
        ], cutoff: 4500, peakDb: -18, room: 0.22),
      ExtraSound.lost => SoundSpec([
          Note(0, _p(_e4), 0.35, voice: Voice.soft),
          Note(0.18, _p(_d4), 0.6, voice: Voice.soft),
        ], cutoff: 2500, peakDb: -18),
      ExtraSound.back => SoundSpec([
          Note(0, _p(_d4 + 12), 0.3, voice: Voice.soft),
          Note(0.12, _p(_a4), 0.5, voice: Voice.soft),
          Note(0.12, _p(_d5), 0.5, gain: 0.5),
        ], cutoff: 4000, peakDb: -18),
      ExtraSound.image => SoundSpec([
          Note(0, _p(_e6), 0.12, voice: Voice.pluck, gain: 0.6),
          Note(0.05, _p(_b5), 0.18, gain: 0.7),
          Note(0.1, _p(_a6), 0.35, gain: 0.6),
        ], cutoff: 6000, peakDb: -20, room: 0.1),
      ExtraSound.mention => SoundSpec([
          Note(0, _p(_d6), 0.25),
          Note(0.09, _p(_a5), 0.25, gain: 0.8),
          Note(0.18, _p(_d6), 0.45),
        ], cutoff: 6000, peakDb: -17),
    };
