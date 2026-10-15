import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/audio/sound_engine.dart';
import 'package:starsync/src/sfx/sfx.dart';
import 'package:starsync/src/sfx/sound_bank.dart';
import 'package:starsync/src/sfx/synth_sfx.dart';

// Needs a real audio output: opens the device through flutter_soloud and
// plays every sound of every preset once, quietly (WT_SFX_VOLUME, default
// 0.1, on the square curve like the app).

void main() {
  // flutter_soloud's init asks path_provider for a temp dir.
  TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), (_) async => Directory.systemTemp.path);
  test('every sound loads and plays on the real device', timeout: const Timeout(Duration(minutes: 2)), () async {
    final volume = double.tryParse(Platform.environment['WT_SFX_VOLUME'] ?? '') ?? 0.1;
    final engine = SoundEngine();
    expect(await engine.warmUp(), isTrue, reason: 'audio device opened');
    final sfx = SynthSfx(volume: () => volume, engine: engine);
    for (final p in SoundPreset.values) {
      for (final k in SfxKind.values) {
        await sfx.preview(k, readyIndex: 2, preset: p);
        expect(SoLoud.instance.getActiveVoiceCount(), greaterThan(0), reason: '${p.name}/${k.name}');
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await sfx.dispose();
    expect(SoLoud.instance.isInitialized, isFalse);
  });
}
