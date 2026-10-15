import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/platform/audio/sound_engine.dart';
import 'package:watch_together/src/sfx/sfx.dart';
import 'package:watch_together/src/sfx/sound_bank.dart';
import 'package:watch_together/src/sfx/synth.dart';
import 'package:watch_together/src/sfx/synth_sfx.dart';

class _FakeBackend implements AudioBackend {
  final bool failInit;
  _FakeBackend({this.failInit = false});

  var inits = 0, deinits = 0;
  final loads = <String, Uint8List>{};
  final unloaded = <Object>[];
  final plays = <(String, double)>[];

  @override
  Future<void> init() async {
    inits++;
    if (failInit) throw StateError('no audio device');
  }

  @override
  Future<Object> load(String name, Uint8List wav) async {
    loads[name] = wav;
    return name;
  }

  @override
  void play(Object sound, double volume) => plays.add((sound as String, volume));

  @override
  Future<void> unload(Object sound) async => unloaded.add(sound);

  @override
  Future<void> deinit() async => deinits++;
}

Future<Uint8List> _bytes() async => Uint8List.fromList([1, 2, 3]);

void main() {
  test('loads a sound once per key and lets plays overlap', () async {
    final b = _FakeBackend();
    final e = SoundEngine(backend: b);
    await Future.wait([
      e.play('chat', 'abyss-chat', _bytes, volume: 0.5),
      e.play('chat', 'abyss-chat', _bytes, volume: 0.5),
    ]);
    await e.play('chat', 'abyss-chat', _bytes, volume: 0.25);
    expect(b.inits, 1);
    expect(b.loads.length, 1);
    expect(b.plays.map((p) => p.$2), [0.5, 0.5, 0.25]);
  });

  test('a new key or fresh replaces and frees the slot', () async {
    final b = _FakeBackend();
    final e = SoundEngine(backend: b);
    await e.play('chat', 'abyss-chat', _bytes, volume: 1);
    await e.play('chat', 'cosmic-chat', _bytes, volume: 1);
    await e.play('chat', 'cosmic-chat', _bytes, volume: 1, fresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(b.loads.length, 3);
    expect(b.loads.keys.toSet().length, 3, reason: 'load names are unique');
    expect(b.unloaded.length, 2);
    expect(b.plays.map((p) => p.$1).toSet().length, 3);
  });

  test('silence and zero volume load nothing', () async {
    final b = _FakeBackend();
    final e = SoundEngine(backend: b);
    await e.play('chat', 'abyss-chat', _bytes, volume: 0);
    expect(b.inits, 0);
    expect(b.loads, isEmpty);
  });

  test('a failed init means no sounds, no throw, one try', () async {
    final b = _FakeBackend(failInit: true);
    final e = SoundEngine(backend: b);
    expect(await e.warmUp(), isFalse);
    await e.play('chat', 'abyss-chat', _bytes, volume: 1);
    await e.play('join', 'abyss-join', _bytes, volume: 1);
    expect(b.inits, 1);
    expect(b.loads, isEmpty);
    expect(b.plays, isEmpty);
    await e.dispose();
    expect(b.deinits, 0);
  });

  test('a failed render is retried on the next play', () async {
    final b = _FakeBackend();
    final e = SoundEngine(backend: b);
    await e.play('chat', 'abyss-chat', () async => throw StateError('render'), volume: 1);
    expect(b.plays, isEmpty);
    await e.play('chat', 'abyss-chat', _bytes, volume: 1);
    expect(b.plays.length, 1);
  });

  test('dispose deinits once and drops later plays', () async {
    final b = _FakeBackend();
    final e = SoundEngine(backend: b);
    await e.play('chat', 'abyss-chat', _bytes, volume: 1);
    await e.dispose();
    await e.dispose();
    await e.play('chat', 'abyss-chat', _bytes, volume: 1);
    expect(b.deinits, 1);
    expect(b.plays.length, 1);
  });

  test('dispose without a sound ever played opens nothing', () async {
    final b = _FakeBackend();
    await SoundEngine(backend: b).dispose();
    expect(b.inits + b.deinits, 0);
  });

  group('SynthSfx', () {
    test('renders a WAV per sound, volume as before (v^6), switches and preview', () async {
      final b = _FakeBackend();
      var volume = 0.5;
      final off = <SfxKind>{SfxKind.join};
      final sfx = SynthSfx(
        volume: () => volume,
        enabled: (k) => !off.contains(k),
        presetFor: (_) => SoundPreset.woodAndGlass,
        engine: SoundEngine(backend: b),
      );
      for (final k in SfxKind.values) {
        await sfx.play(SfxCue(k, readyIndex: 2));
      }
      expect(b.plays.length, SfxKind.values.length - 1);
      expect(b.plays.every((p) => p.$2 == 0.015625), isTrue); // 0.5^6
      for (final MapEntry(:key, :value) in b.loads.entries) {
        expect(String.fromCharCodes(value.sublist(0, 4)), 'RIFF', reason: key);
        expect(key, startsWith('woodAndGlass-'));
      }
      final chat = b.loads.entries.firstWhere((e) => e.key.startsWith('woodAndGlass-chat-2'));
      expect(chat.value, wav(render(soundFor(SfxKind.chat, readyIndex: 2, preset: SoundPreset.woodAndGlass))));

      await sfx.preview(SfxKind.join, readyIndex: 2);
      expect(b.plays.last.$1, startsWith('woodAndGlass-join-2'));

      volume = 0;
      await sfx.play(const SfxCue(SfxKind.chat));
      expect(b.plays.length, SfxKind.values.length);
      await sfx.dispose();
      expect(b.deinits, 1);
    });
  });
}
