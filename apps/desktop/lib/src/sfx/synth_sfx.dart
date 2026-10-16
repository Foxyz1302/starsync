import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/audio/sound_engine.dart';
import 'sfx.dart';
import 'sound_bank.dart';
import 'synth.dart';

/// Plays [SoundSpec]s on a [SoundEngine]: each is rendered once (off the
/// UI isolate) to WAV bytes and loaded into memory; sounds overlap.
/// [volume] (0..1) is read per play and applied as v^6: the square curve
/// (ears are log) the app always used, times mpv's own cubic volume it
/// used to play through, so the slider sounds as it did; [enabled]
/// filters cues.
class SynthSfx implements SfxService {
  final double Function() volume;
  final bool Function(SfxKind kind) enabled;
  /// Which sound set each sound plays from.
  final SoundPreset Function(SfxKind kind) presetFor;
  final SoundEngine engine;
  SynthSfx(
      {required this.volume,
      bool Function(SfxKind kind)? enabled,
      SoundPreset Function(SfxKind kind)? presetFor,
      SoundEngine? engine})
      : enabled = enabled ?? ((_) => true),
        presetFor = presetFor ?? ((_) => defaultPreset),
        engine = engine ?? SoundEngine();

  @override
  Future<void> play(SfxCue cue) {
    if (!enabled(cue.kind)) return Future.value();
    return _play(cue.kind, cue.readyIndex, presetFor(cue.kind));
  }

  /// Plays [kind] even when it is switched off (Settings' preview), always
  /// freshly rendered: an edited spec plays after a hot reload.
  Future<void> preview(SfxKind kind, {int readyIndex = 1, SoundPreset? preset}) {
    // Asked for: try the device again even after a crash kept it closed.
    engine.retry();
    return _play(kind, readyIndex, preset ?? presetFor(kind), fresh: true);
  }

  /// One slot per sound and ready step: a new preset replaces it.
  Future<void> _play(SfxKind kind, int readyIndex, SoundPreset preset, {bool fresh = false}) {
    final v = volume();
    return engine.play('${kind.name}-$readyIndex', '${preset.name}-${kind.name}-$readyIndex',
        () => renderWav(soundFor(kind, readyIndex: readyIndex, preset: preset)),
        volume: math.pow(v, 6).toDouble(), fresh: fresh);
  }

  /// Opens the audio device ahead of the first sound.
  Future<void> warmUp() => engine.warmUp();

  Future<void> dispose() => engine.dispose();
}

/// [spec] as WAV bytes, rendered on a worker isolate.
Future<Uint8List> renderWav(SoundSpec spec) => compute(_renderWav, spec, debugLabel: 'sfx render');

Uint8List _renderWav(SoundSpec spec) => wav(render(spec));
