import 'sfx.dart';
import 'synth.dart';

// The app's sounds come in presets; each action can take its sound from any
// of them. Every preset is quiet, short and on D, so sounds from different
// presets still agree when they overlap.
//  - Cosmic: star bells, stardust, bubbles, soft pads, a space tail.
//  - Abyss: deep space and its dread. Far beacons, nebula washes, slow
//    beating clusters and tritone sags, on D phrygian, with a vast tail.
//  - Wood & glass: plucked strings, glass bells, wood knocks, a short room.

enum SoundPreset { cosmic, abyss, woodAndGlass }

/// Shown in Settings: name and feel.
const presetInfo = {
  SoundPreset.cosmic: ('Cosmic', 'Star bells, stardust and a soft space tail'),
  SoundPreset.abyss: ('Abyss', 'Deep space: far beacons, nebula, a vast dark tail'),
  SoundPreset.woodAndGlass: ('Wood & glass', 'Plucked strings, glass bells and wood, close and dry'),
};

/// The preset used when nothing else is chosen.
const defaultPreset = SoundPreset.abyss;

const _d3 = -19, _ab3 = -13;
const _d4 = -7, _eb4 = -6, _ab4 = -1, _a4 = 0, _b4 = 2;
const _d5 = 5, _eb5 = 6, _e5 = 7, _f5 = 8, _fs5 = 9, _g5 = 10, _a5 = 12, _bb5 = 13, _b5 = 14;
const _c6 = 15, _cs6 = 16, _d6 = 17, _e6 = 19, _f6 = 20, _fs6 = 21, _g6 = 22, _a6 = 24, _b6 = 26;

double _p(int s) => semi(s);

/// The ready sound's answer climbs with each person ready.
const _cosmicLadder = [_a5, _b5, _d6, _e6, _fs6, _a6];
const _abyssLadder = [_f5, _g5, _a5, _c6, _d6, _f6];
const _woodLadder = [_g5, _a5, _b5, _d6, _e6, _g6];

SoundSpec readySound(int readyIndex, {SoundPreset preset = defaultPreset}) =>
    soundFor(SfxKind.ready, readyIndex: readyIndex, preset: preset);

SoundSpec soundFor(SfxKind kind, {int readyIndex = 1, SoundPreset preset = defaultPreset}) {
  final i = (readyIndex - 1).clamp(0, 5);
  return switch (preset) {
    SoundPreset.cosmic => _cosmic(kind, i),
    SoundPreset.abyss => _abyss(kind, i),
    SoundPreset.woodAndGlass => _wood(kind, i),
  };
}

SoundSpec _cosmic(SfxKind kind, int i) => switch (kind) {
      SfxKind.ready => SoundSpec([
          Note(0, _p(_d4), 1.0, voice: Voice.pad, gain: 0.3),
          Note(0, _p(_d5), 1.2, voice: Voice.star, gain: 0.8, bright: 0.4),
          Note(0.09, _p(_cosmicLadder[i]), 1.5, voice: Voice.star, bright: 0.5),
        ], peakDb: -17, room: 0.3),
      // The same bells, dimmed and stepping down.
      SfxKind.unready => SoundSpec([
          Note(0, _p(_fs5), 0.6, voice: Voice.star, gain: 0.8, bright: 0.15),
          Note(0.1, _p(_d5), 0.8, voice: Voice.star, bright: 0.1),
        ], cutoff: 3500, peakDb: -20, room: 0.25),
      // Just the bell, left hanging in space: playback is the rest of the cue.
      SfxKind.forceReady => SoundSpec([
          Note(0, _p(_d6), 1.8, voice: Voice.star, bright: 0.7),
        ], cutoff: 7000, peakDb: -18, room: 0.35, tail: 1.6),
      // A star arriving: dust rising into a bell.
      SfxKind.join => SoundSpec([
          Note(0, _p(_d6), 1.0, voice: Voice.dust, to: _p(_a6), gain: 0.5),
          Note(0.15, _p(_a5), 1.4, voice: Voice.star, bright: 0.35, gain: 0.6),
        ], cutoff: 7000, peakDb: -19, room: 0.3),
      // Dust drifting down, a low bell going out.
      SfxKind.leave => SoundSpec([
          Note(0, _p(_a6), 0.9, voice: Voice.dust, to: _p(_d6), gain: 0.5),
          Note(0.1, _p(_d5), 1.3, voice: Voice.star, bright: 0.2, gain: 0.5),
        ], cutoff: 5000, peakDb: -22, room: 0.3),
      // Falling into the dark: a deep tone sinking an octave under a sagging pad.
      SfxKind.kick => SoundSpec([
          Note(0, _p(_d4), 1.0, voice: Voice.sub, to: _p(_d3)),
          Note(0, _p(_a4), 0.9, voice: Voice.pad, to: _p(_d4), gain: 0.4),
        ], cutoff: 3000, peakDb: -19, room: 0.25),
      // Something new opens up: a rush of air, then a wide chord blooms.
      SfxKind.swap => SoundSpec([
          Note(0, 300, 0.6, voice: Voice.slide, to: 2400, gain: 0.35),
          Note(0.35, _p(_d4), 1.4, voice: Voice.pad, gain: 0.5, bright: 0.3),
          Note(0.35, _p(_a4), 1.4, voice: Voice.pad, gain: 0.5, bright: 0.3),
          Note(0.35, _p(_e5), 1.4, voice: Voice.pad, gain: 0.4, bright: 0.3),
          Note(0.38, _p(_fs6), 1.2, voice: Voice.star, bright: 0.3, gain: 0.3),
        ], peakDb: -18, room: 0.3),
      // Two bubbles rising: bloop-bloop, the second higher.
      SfxKind.chat => SoundSpec([
          Note(0, _p(_a5), 0.18, voice: Voice.drop, gain: 0.8),
          Note(0.08, _p(_e6), 0.22, voice: Voice.drop),
        ], peakDb: -19, room: 0.15, tail: 1.0),
      // Something huge drifting past: a slow, deep swell.
      SfxKind.warn => SoundSpec([
          Note(0, _p(_d4), 2.0, voice: Voice.pad),
          Note(0, _p(_a4), 2.0, voice: Voice.pad, gain: 0.5),
          Note(0.3, _p(_d3), 1.7, voice: Voice.sub, gain: 0.4),
        ], cutoff: 3000, peakDb: -20, room: 0.2, tail: 1.0),
      // The signal fading: a chord sagging down and dimming.
      SfxKind.lost => SoundSpec([
          Note(0, _p(_a4), 1.2, voice: Voice.pad, to: _p(_d4), gain: 0.7),
          Note(0, _p(_e5), 1.2, voice: Voice.pad, to: _p(_a4), gain: 0.4),
        ], cutoff: 2500, peakDb: -19, room: 0.3, tail: 1.2),
      // Re-acquired: a bell gliding up into tune, landing with dust.
      SfxKind.back => SoundSpec([
          Note(0, _p(_a4), 0.6, voice: Voice.star, to: _p(_d5), bright: 0.3, gain: 0.5),
          Note(0.22, _p(_a5), 1.2, voice: Voice.star, bright: 0.5),
          Note(0.25, _p(_d6), 0.6, voice: Voice.dust, to: _p(_a6), gain: 0.3),
        ], peakDb: -18, room: 0.25),
      // A poke: two quick bright bubbles flicking up, a glint on the second.
      // High and dry so it cuts through a video and stays a patter when spammed.
      SfxKind.nudge => SoundSpec([
          Note(0, _p(_d6), 0.12, voice: Voice.drop, to: _p(_fs6), gain: 0.8),
          Note(0.09, _p(_a6), 0.16, voice: Voice.drop),
          Note(0.09, _p(_cs6) * 2, 0.3, voice: Voice.star, bright: 0.6, gain: 0.2),
        ], cutoff: 7000, peakDb: -18, room: 0.05, tail: 0.6),
    };

SoundSpec _abyss(SfxKind kind, int i) => switch (kind) {
      // A beacon pinging far out, the void humming under it.
      SfxKind.ready => SoundSpec([
          Note(0, _p(_d3), 1.2, voice: Voice.pad, gain: 0.35),
          Note(0, _p(_d5), 1.4, voice: Voice.star, gain: 0.8, bright: 0.25),
          Note(0.12, _p(_abyssLadder[i]), 1.6, voice: Voice.star, bright: 0.3),
        ], cutoff: 5000, peakDb: -18, room: 0.4, tail: 1.8),
      // The beacon answering itself a tritone down, dimmer.
      SfxKind.unready => SoundSpec([
          Note(0, _p(_a4), 0.7, voice: Voice.star, gain: 0.8, bright: 0.1),
          Note(0.12, _p(_eb4), 0.9, voice: Voice.star, bright: 0.1),
        ], cutoff: 2500, peakDb: -21, room: 0.35, tail: 1.6),
      // One bell, huge and very far away.
      SfxKind.forceReady => SoundSpec([
          Note(0, _p(_d5), 1.7, voice: Voice.star, bright: 0.5),
        ], cutoff: 5000, peakDb: -18, room: 0.45, tail: 1.8),
      // Something emerging from the nebula: a dark wash brightening into a bell.
      SfxKind.join => SoundSpec([
          Note(0, 150, 1.2, voice: Voice.slide, to: 900, gain: 0.4),
          Note(0.05, _p(_d4), 1.2, voice: Voice.pad, gain: 0.3),
          Note(0.3, _p(_a5), 1.3, voice: Voice.star, bright: 0.3, gain: 0.5),
        ], cutoff: 4500, peakDb: -19, room: 0.4, tail: 1.6),
      // Swallowed back into it: the wash darkening over a fading bell.
      SfxKind.leave => SoundSpec([
          Note(0, 900, 1.1, voice: Voice.slide, to: 150, gain: 0.4),
          Note(0.1, _p(_d5), 1.2, voice: Voice.star, bright: 0.15, gain: 0.4),
        ], cutoff: 3500, peakDb: -22, room: 0.4, tail: 1.6),
      // Pulled under: a deep fall with a tritone sagging over it.
      SfxKind.kick => SoundSpec([
          Note(0, _p(_d4), 1.3, voice: Voice.sub, to: _p(_d3)),
          Note(0, _p(_ab4), 1.2, voice: Voice.pad, to: _p(_d4), gain: 0.35),
        ], cutoff: 2000, peakDb: -19, room: 0.35, tail: 1.6),
      // A door into the dark: low air, then an unresolved chord opens.
      SfxKind.swap => SoundSpec([
          Note(0, 120, 0.8, voice: Voice.slide, to: 1200, gain: 0.35),
          Note(0.45, _p(_d4), 1.3, voice: Voice.pad, gain: 0.5, bright: 0.2),
          Note(0.45, _p(_a4), 1.3, voice: Voice.pad, gain: 0.45, bright: 0.2),
          Note(0.45, _p(_eb5), 1.3, voice: Voice.pad, gain: 0.3, bright: 0.2),
          Note(0.5, _p(_bb5), 1.1, voice: Voice.star, bright: 0.2, gain: 0.25),
        ], cutoff: 4000, peakDb: -19, room: 0.35, tail: 1.4),
      // Bubbles rising from deep water.
      SfxKind.chat => SoundSpec([
          Note(0, _p(_d5), 0.25, voice: Voice.drop, gain: 0.8),
          Note(0.1, _p(_a5), 0.3, voice: Voice.drop),
        ], cutoff: 4500, peakDb: -19, room: 0.3, tail: 1.4),
      // Something vast drawing near: a slow swell of two notes rubbing.
      SfxKind.warn => SoundSpec([
          Note(0, _p(_d4), 2.0, voice: Voice.pad),
          Note(0, _p(_eb4), 2.0, voice: Voice.pad, gain: 0.35),
          Note(0.3, _p(_d3), 1.7, voice: Voice.sub, gain: 0.45),
        ], cutoff: 2200, peakDb: -20, room: 0.25, tail: 1.0),
      // The signal drowning: a chord sagging by a tritone into static.
      SfxKind.lost => SoundSpec([
          Note(0, _p(_a4), 1.3, voice: Voice.pad, to: _p(_eb4), gain: 0.7),
          Note(0, _p(_d4), 1.3, voice: Voice.pad, to: _p(_ab3), gain: 0.5),
          Note(0.2, 600, 1.0, voice: Voice.slide, to: 200, gain: 0.2),
        ], cutoff: 2000, peakDb: -19, room: 0.35, tail: 1.4),
      // Found again: a bell climbing out of the tritone into tune.
      SfxKind.back => SoundSpec([
          Note(0, _p(_ab4), 0.6, voice: Voice.star, to: _p(_d5), bright: 0.25, gain: 0.5),
          Note(0.25, _p(_a5), 1.3, voice: Voice.star, bright: 0.4),
          Note(0.28, _p(_d5), 0.6, voice: Voice.dust, to: _p(_a5), gain: 0.25),
        ], cutoff: 5000, peakDb: -18, room: 0.35, tail: 1.6),
      // A poke from the dark: two quick bubbles flicking up, a pale glint.
      // Still high and fairly dry so it cuts through a video when spammed.
      SfxKind.nudge => SoundSpec([
          Note(0, _p(_a5), 0.13, voice: Voice.drop, to: _p(_c6), gain: 0.8),
          Note(0.1, _p(_d6), 0.18, voice: Voice.drop),
          Note(0.1, _p(_a6), 0.35, voice: Voice.star, bright: 0.5, gain: 0.2),
        ], cutoff: 6000, peakDb: -18, room: 0.1, tail: 1.0),
    };

SoundSpec _wood(SfxKind kind, int i) => switch (kind) {
      SfxKind.ready => SoundSpec([
          Note(0, _p(_d5), 0.9, gain: 0.75, bright: 0.55),
          Note(0.085, _p(_woodLadder[i]), 1.1, bright: 0.65),
        ], peakDb: -17, room: 0.14, tail: 0.5),
      // The same strings, muted and stepping down.
      SfxKind.unready => SoundSpec([
          Note(0, _p(_a5), 0.35, gain: 0.8, bright: 0.2),
          Note(0.09, _p(_g5), 0.45, bright: 0.15),
        ], cutoff: 3800, peakDb: -20, room: 0.1, tail: 0.5),
      // Just the bell: playback starting is the rest of the cue.
      SfxKind.forceReady => SoundSpec([
          Note(0, _p(_d6) * 2, 1.6, voice: Voice.chime),
        ], cutoff: 7000, peakDb: -18, room: 0.18, tail: 0.5),
      // Wind through glass: three uneven tinkles.
      SfxKind.join => SoundSpec([
          Note(0, _p(_a6), 1.3, voice: Voice.chime, gain: 0.8),
          Note(0.11, _p(_d6) * 2, 1.2, voice: Voice.chime, gain: 0.55),
          Note(0.26, _p(_e6) * 2, 1.4, voice: Voice.chime, gain: 0.45),
        ], cutoff: 7000, peakDb: -19, room: 0.18, tail: 0.5),
      // The wind settling: two softer, lower tinkles.
      SfxKind.leave => SoundSpec([
          Note(0, _p(_b6), 1.0, voice: Voice.chime, gain: 0.6),
          Note(0.17, _p(_e6), 1.3, voice: Voice.chime, gain: 0.5),
        ], cutoff: 5000, peakDb: -22, room: 0.18, tail: 0.5),
      // Two hardwood clacks, then a low muted string.
      SfxKind.kick => SoundSpec([
          Note(0, 1900, 0.09, voice: Voice.clack),
          Note(0.16, 1750, 0.11, voice: Voice.clack, gain: 0.9),
          Note(0.3, _p(_d4), 0.7, bright: 0.15, gain: 0.7),
        ], cutoff: 5000, peakDb: -19, room: 0.12, tail: 0.5),
      // The door slides open on something new: air, then a fifth.
      SfxKind.swap => SoundSpec([
          Note(0, 500, 0.42, voice: Voice.slide, to: 1700, gain: 0.5),
          Note(0.33, _p(_d5), 1.1, bright: 0.6, gain: 0.8),
          Note(0.36, _p(_a5), 1.1, bright: 0.6, gain: 0.7),
        ], peakDb: -18, tail: 0.5),
      // A hollow wooden tok-tok, the second higher.
      SfxKind.chat => SoundSpec([
          Note(0, _p(_g5), 0.13, voice: Voice.bamboo, gain: 0.85),
          Note(0.075, _p(_d6), 0.16, voice: Voice.bamboo),
        ], cutoff: 5500, peakDb: -19, room: 0.1, tail: 0.5),
      // A bowl: one soft strike that hums.
      SfxKind.warn => SoundSpec([
          Note(0, _p(_d5), 2.6, voice: Voice.rin),
        ], cutoff: 4500, peakDb: -20, room: 0.1, tail: 0.5),
      // A string going slack: plucked, its pitch sagging away.
      SfxKind.lost => SoundSpec([
          Note(0, _p(_a5), 1.1, to: _p(_d5), bright: 0.4),
          Note(0.05, _p(_d5), 1.0, to: _p(_a4), bright: 0.3, gain: 0.6),
        ], cutoff: 3500, peakDb: -19, tail: 0.5),
      // Re-tuned: a quick bend up that lands, and a tinkle.
      SfxKind.back => SoundSpec([
          Note(0, _p(_b4), 0.9, to: _p(_d5), bright: 0.5),
          Note(0.2, _p(_a5), 1.0, bright: 0.6, gain: 0.7),
          Note(0.3, _p(_d6) * 2, 1.0, voice: Voice.chime, gain: 0.2),
        ], peakDb: -18, tail: 0.5),
          // Two quick wooden taps, the second flicking up, with a glint.
      SfxKind.nudge => SoundSpec([
          Note(0, _p(_a5), 0.12, voice: Voice.bamboo, gain: 0.8),
          Note(0.09, _p(_e6), 0.16, voice: Voice.bamboo),
          Note(0.09, _p(_b6), 0.35, voice: Voice.chime, gain: 0.3),
        ], cutoff: 6500, peakDb: -18, room: 0.04, tail: 0.5),
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
  SfxKind.nudge: ('Nudge', 'Someone nudges you to get your attention'),
};
