import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:sync_relay_core/core.dart';

final _log = createLogger('sound');

/// What [SoundEngine] needs from an audio library: [SoLoudBackend] in the
/// app, a fake in tests. A sound handle is whatever [load] returns.
abstract class AudioBackend {
  Future<void> init();
  /// Decodes [wav] (a whole WAV file) into memory under [name].
  Future<Object> load(String name, Uint8List wav);
  /// Starts one voice of [sound] at [volume] (linear gain, 0..1); voices
  /// overlap.
  void play(Object sound, double volume);
  Future<void> unload(Object sound);
  Future<void> deinit();
}

/// flutter_soloud (SoLoud mixing into miniaudio's output device).
class SoLoudBackend implements AudioBackend {
  SoLoud get _s => SoLoud.instance;

  @override
  Future<void> init() => _s.init();

  @override
  Future<Object> load(String name, Uint8List wav) => _s.loadMem(name, wav);

  @override
  void play(Object sound, double volume) => _s.play(sound as AudioSource, volume: volume);

  @override
  Future<void> unload(Object sound) => _s.disposeSource(sound as AudioSource);

  @override
  Future<void> deinit() => _s.deinitAsync();
}

/// The app's short in-memory sounds. The audio device opens on [warmUp] or
/// the first [play]; if it can't (no device, a broken driver) the engine
/// logs once and every play is silently dropped. Each sound is loaded once
/// per slot from the WAV bytes its renderer gives; a new key in a slot
/// replaces (and frees) what the slot held.
class SoundEngine {
  final AudioBackend _backend;
  SoundEngine({AudioBackend? backend}) : _backend = backend ?? SoLoudBackend();

  Future<bool>? _ready;
  var _disposed = false;

  /// A file that exists only while the audio device is opening (set by the
  /// app). Found at the next start, the last open took the app down (a
  /// native crash in the driver or miniaudio, seen on Windows): sounds stay
  /// off rather than crash every start, until [retry] (Settings' preview).
  String? crashMark;
  var _skipped = false;
  /// Per slot: the loaded key and its sound (null: failed to load).
  final Map<String, (String, Future<Object?>)> _slots = {};
  /// Load names are unique: SoLoud hands back the old sound for a name it
  /// already holds, which would defeat a re-render.
  var _loads = 0;

  /// Opens the audio device now, so the first sound has no wait.
  Future<bool> warmUp() => _ready ??= _init();

  Future<bool> _init() async {
    if (_disposed) return false;
    final mark = crashMark == null ? null : File(crashMark!);
    try {
      if (mark != null && mark.existsSync()) {
        _skipped = true;
        _log.warning('no sounds: opening the audio device crashed the app last time '
            '(${mark.path}); a sound preview in Settings tries again');
        return false;
      }
      mark?.writeAsStringSync('opening the audio device');
    } catch (_) {}
    _log.info('opening the audio device');
    try {
      await _backend.init();
      _log.info('audio device open');
      return true;
    } catch (e) {
      _log.warning('no sounds: audio init failed: $e');
      return false;
    } finally {
      try {
        if (mark != null && mark.existsSync()) mark.deleteSync();
      } catch (_) {}
    }
  }

  /// Opens the device again after a crash mark kept sounds off (the user
  /// asked for a sound). A real crash leaves the mark again.
  void retry() {
    if (!_skipped) return;
    _skipped = false;
    try {
      final m = crashMark;
      if (m != null) File(m).deleteSync();
    } catch (_) {}
    _ready = null;
  }

  /// Plays the sound of [slot] at [volume] (linear gain). [key] names what
  /// [wav] renders: the same key reuses the loaded sound; another key, or
  /// [fresh], renders and loads it again.
  Future<void> play(String slot, String key, Future<Uint8List> Function() wav,
      {required double volume, bool fresh = false}) async {
    if (_disposed || volume <= 0) return;
    if (!await warmUp() || _disposed) return;
    var held = _slots[slot];
    if (held == null || held.$1 != key || fresh) {
      if (held != null) unawaited(_unload(held.$2));
      held = (key, _load(key, wav));
      _slots[slot] = held;
    }
    final sound = await held.$2;
    if (sound == null) {
      // Retry on the next play.
      if (identical(_slots[slot], held)) _slots.remove(slot);
      return;
    }
    if (_disposed || !identical(_slots[slot], held)) return;
    try {
      _backend.play(sound, volume.clamp(0.0, 1.0));
    } catch (e) {
      _log.warning('sound $key: $e');
    }
  }

  Future<Object?> _load(String key, Future<Uint8List> Function() wav) async {
    try {
      return await _backend.load('$key#${_loads++}', await wav());
    } catch (e) {
      _log.warning('sound $key: $e');
      return null;
    }
  }

  Future<void> _unload(Future<Object?> sound) async {
    try {
      final s = await sound;
      if (s != null && !_disposed) await _backend.unload(s);
    } catch (e) {
      _log.fine('unload: $e');
    }
  }

  /// Frees every sound and closes the audio device. Plays after it are
  /// dropped.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _slots.clear();
    final ready = _ready;
    if (ready == null || !await ready) return;
    try {
      // Deinit frees the loaded sounds with the engine.
      await _backend.deinit();
    } catch (e) {
      _log.warning('audio deinit: $e');
    }
  }
}
