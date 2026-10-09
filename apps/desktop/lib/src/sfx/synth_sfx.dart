import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'sfx.dart';
import 'sound_bank.dart';
import 'synth.dart';

/// Plays [SoundSpec]s: each is rendered once to a WAV in the temp dir and
/// played on a small pool of audio-only mpv players (so two sounds can
/// overlap). [volume] (0..1) is read per play and applied on a square
/// curve (ears are log); [enabled] filters cues.
class SynthSfx implements SfxService {
  final double Function() volume;
  final bool Function(SfxKind kind) enabled;
  /// Which sound set each sound plays from.
  final SoundPreset Function(SfxKind kind) presetFor;
  SynthSfx({required this.volume, bool Function(SfxKind kind)? enabled, SoundPreset Function(SfxKind kind)? presetFor})
      : enabled = enabled ?? ((_) => true),
        presetFor = presetFor ?? ((_) => defaultPreset);

  static const _poolSize = 3;
  final List<Player> _pool = [];
  var _next = 0;
  final Map<String, Future<String>> _files = {};
  Directory? _dir;

  @override
  Future<void> play(SfxCue cue) async {
    if (!enabled(cue.kind)) return;
    final preset = presetFor(cue.kind);
    await playSpec('${preset.name}-${cue.kind.name}-${cue.readyIndex}',
        soundFor(cue.kind, readyIndex: cue.readyIndex, preset: preset));
  }

  /// Plays [kind] even when it is switched off (Settings' preview), always
  /// freshly rendered: an edited spec plays after a hot reload.
  Future<void> preview(SfxKind kind, {int readyIndex = 1, SoundPreset? preset}) {
    final p = preset ?? presetFor(kind);
    final key = '${p.name}-${kind.name}-$readyIndex';
    _files.remove(key);
    return playSpec(key, soundFor(kind, readyIndex: readyIndex, preset: p));
  }

  /// Plays [spec], cached under [key] (same key = same sound).
  Future<void> playSpec(String key, SoundSpec spec) async {
    final v = volume();
    if (v <= 0) return;
    try {
      final path = await (_files[key] ??= _write(key, spec));
      final player = await _player();
      await player.setVolume(100 * v * v);
      await player.open(Media(path));
    } catch (e) {
      _files.remove(key);
      debugPrint('sfx $key: $e');
    }
  }

  Future<String> _write(String key, SoundSpec spec) async {
    _dir ??= await Directory('${(await getTemporaryDirectory()).path}/watch_together_sfx').create(recursive: true);
    final f = File('${_dir!.path}/$key.wav');
    await f.writeAsBytes(wav(render(spec)));
    return f.path;
  }

  Future<Player> _player() async {
    if (_pool.length < _poolSize) {
      final p = Player(
        configuration: const PlayerConfiguration(vo: 'null', osc: false, libass: false, title: 'sfx'),
      );
      await (p.platform as NativePlayer).setProperty('audio-display', 'no');
      _pool.add(p);
      return p;
    }
    return _pool[_next++ % _poolSize];
  }

  Future<void> dispose() async {
    for (final p in _pool) {
      await p.dispose();
    }
    _pool.clear();
  }
}
