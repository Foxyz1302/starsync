import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:watch_together/src/playback/playback_controller.dart';
import 'package:watch_together/src/shaders/shader_assets.dart';
import 'package:watch_together/src/shaders/shader_presets.dart';
import 'package:watch_together/src/state/settings.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Headless mpv (no video output) still takes and reports glsl-shaders.
  test('real mpv: presets set glsl-shaders live, failures fall back to off',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    MediaKit.ensureInitialized();
    final support = Directory('$_tmp/shaders_mpv_support');
    if (support.existsSync()) support.deleteSync(recursive: true);
    support.createSync(recursive: true);
    shaderSupportDir = () async => support;
    final s = AppSettings.instance;
    final p = PlaybackController();
    try {
      // The saved choice goes on at player creation.
      s.setShaderPreset(ShaderPreset.a);
      await p.init();
      final dynamic mpv = p.player.platform;
      final modeA = joinShaderPaths(
          await shaderPathsFor(ShaderPreset.a, ShaderQuality.hq, const []));
      expect(await mpv.getProperty('glsl-shaders'), modeA);
      expect(p.shaderNotice.value, isNull);

      // Live change, announced.
      s.setShaderPreset(ShaderPreset.ca);
      s.setShaderQuality(ShaderQuality.fast);
      await p.applyShaders(announce: true);
      final caFast = await shaderPathsFor(
          ShaderPreset.ca, ShaderQuality.fast, const []);
      expect(caFast.first, startsWith(support.path));
      expect(await mpv.getProperty('glsl-shaders'), joinShaderPaths(caFast));
      expect(p.shaderNotice.value?.text, 'Shaders: Mode C+A (Fast)');

      // A missing custom file: toast, off, nothing set.
      final good = File('${support.path}/mine.glsl')..writeAsStringSync('//');
      s.setCustomShaders([good.path, '${support.path}/gone.glsl']);
      s.setShaderPreset(ShaderPreset.custom);
      await p.applyShaders(announce: true);
      expect(await mpv.getProperty('glsl-shaders'), '');
      expect(p.shaderNotice.value?.text,
          'Custom shaders failed: "gone.glsl" not found — turned off');
      expect(s.shaderPreset.value, ShaderPreset.off);

      // Custom files that exist.
      s.setCustomShaders([good.path]);
      s.setShaderPreset(ShaderPreset.custom);
      await p.applyShaders();
      expect(await mpv.getProperty('glsl-shaders'), good.path);

      // A recreated player (Reload video) gets the choice again.
      await p.recreate();
      expect(await (p.player.platform as dynamic).getProperty('glsl-shaders'),
          good.path);

      s.setShaderPreset(ShaderPreset.off);
      await p.applyShaders(announce: true);
      expect(await (p.player.platform as dynamic).getProperty('glsl-shaders'),
          '');
      expect(p.shaderNotice.value?.text, 'Shaders: Off');
    } finally {
      await p.dispose();
    }
  });
}
