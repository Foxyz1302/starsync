import 'sfx.dart';
import 'synth.dart';

// The sound of the house: koto for readiness, the wind chime for people
// arriving and leaving, the shoji door for a new video, bamboo for chat,
// clappers for a kick, the singing bowl for the idle warning, a string
// going slack and re-tuned for the connection. All in the Yo scale on D
// (D E G A B), so overlapping sounds agree; quiet and short.

const _d4 = -7, _a4 = 0, _b4 = 2;
const _d5 = 5, _g5 = 10, _a5 = 12, _b5 = 14;
const _d6 = 17, _e6 = 19, _g6 = 22, _a6 = 24, _b6 = 26;

double _p(int s) => semi(s);

/// The ready pluck's answer climbs with each person ready.
const _readyLadder = [_g5, _a5, _b5, _d6, _e6, _g6];

SoundSpec readySound(int readyIndex) {
  final top = _readyLadder[(readyIndex - 1).clamp(0, _readyLadder.length - 1)];
  return SoundSpec([
    Note(0, _p(_d5), 0.9, gain: 0.75, bright: 0.55),
    Note(0.085, _p(top), 1.1, bright: 0.65),
  ], peakDb: -17);
}

SoundSpec soundFor(SfxKind kind, {int readyIndex = 1}) => switch (kind) {
      SfxKind.ready => readySound(readyIndex),
      // The same strings, muted and stepping down.
      SfxKind.unready => SoundSpec([
          Note(0, _p(_a5), 0.35, gain: 0.8, bright: 0.2),
          Note(0.09, _p(_g5), 0.45, bright: 0.15),
        ], cutoff: 3800, peakDb: -20, room: 0.1),
      // Just the bell: playback starting is the rest of the cue.
      SfxKind.forceReady => SoundSpec([
          Note(0, _p(_d6) * 2, 1.6, voice: Voice.chime),
        ], cutoff: 7000, peakDb: -18, room: 0.18),
      // Wind through the furin: three uneven tinkles.
      SfxKind.join => SoundSpec([
          Note(0, _p(_a6), 1.3, voice: Voice.chime, gain: 0.8),
          Note(0.11, _p(_d6) * 2, 1.2, voice: Voice.chime, gain: 0.55),
          Note(0.26, _p(_e6) * 2, 1.4, voice: Voice.chime, gain: 0.45),
        ], cutoff: 7000, peakDb: -19, room: 0.18),
      // The wind settling: two softer, lower tinkles.
      SfxKind.leave => SoundSpec([
          Note(0, _p(_b6), 1.0, voice: Voice.chime, gain: 0.6),
          Note(0.17, _p(_e6), 1.3, voice: Voice.chime, gain: 0.5),
        ], cutoff: 5000, peakDb: -22, room: 0.18),
      // Hyoshigi: clack… clack, then a low muted string.
      SfxKind.kick => SoundSpec([
          Note(0, 1900, 0.09, voice: Voice.clack),
          Note(0.16, 1750, 0.11, voice: Voice.clack, gain: 0.9),
          Note(0.3, _p(_d4), 0.7, bright: 0.15, gain: 0.7),
        ], cutoff: 5000, peakDb: -19, room: 0.12),
      // The door slides open on something new: air, then a fifth.
      SfxKind.swap => SoundSpec([
          Note(0, 500, 0.42, voice: Voice.slide, to: 1700, gain: 0.5),
          Note(0.33, _p(_d5), 1.1, bright: 0.6, gain: 0.8),
          Note(0.36, _p(_a5), 1.1, bright: 0.6, gain: 0.7),
        ], peakDb: -18),
      // Bamboo: a hollow tok-tok, the second higher.
      SfxKind.chat => SoundSpec([
          Note(0, _p(_g5), 0.13, voice: Voice.bamboo, gain: 0.85),
          Note(0.075, _p(_d6), 0.16, voice: Voice.bamboo),
        ], cutoff: 5500, peakDb: -19, room: 0.1),
      // The singing bowl: one soft strike that hums.
      SfxKind.warn => SoundSpec([
          Note(0, _p(_d5), 2.6, voice: Voice.rin),
        ], cutoff: 4500, peakDb: -20, room: 0.1),
      // A string going slack: plucked, its pitch sagging away.
      SfxKind.lost => SoundSpec([
          Note(0, _p(_a5), 1.1, to: _p(_d5), bright: 0.4),
          Note(0.05, _p(_d5), 1.0, to: _p(_a4), bright: 0.3, gain: 0.6),
        ], cutoff: 3500, peakDb: -19),
      // Re-tuned: a quick bend up that lands, and a tinkle.
      SfxKind.back => SoundSpec([
          Note(0, _p(_b4), 0.9, to: _p(_d5), bright: 0.5),
          Note(0.2, _p(_a5), 1.0, bright: 0.6, gain: 0.7),
          Note(0.3, _p(_d6) * 2, 1.0, voice: Voice.chime, gain: 0.2),
        ], peakDb: -18),
    };

/// Shown in Settings → Notifications & sounds: name and when it plays.
const soundInfo = {
  SfxKind.ready: ('Ready', 'Someone presses Space; climbs with each ready person'),
  SfxKind.unready: ('Not ready', 'Someone takes their ready back'),
  SfxKind.forceReady: ('Everyone ready', 'Someone marks everyone ready'),
  SfxKind.join: ('Joined', 'Someone joins the server'),
  SfxKind.leave: ('Left', 'Someone leaves'),
  SfxKind.kick: ('Removed', 'Someone is kicked'),
  SfxKind.swap: ('New video', 'A different video or episode is put up'),
  SfxKind.chat: ('Message', 'A chat message from someone else'),
  SfxKind.warn: ('Idle warning', 'Auto-unready soon unless you press Space'),
  SfxKind.lost: ('Connection lost', 'The server stopped answering; reconnecting'),
  SfxKind.back: ('Reconnected', 'Back in the server after a drop'),
};
