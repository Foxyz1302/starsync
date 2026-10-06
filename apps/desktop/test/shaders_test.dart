import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:watch_together/src/shaders/shader_assets.dart';
import 'package:watch_together/src/shaders/shader_presets.dart';
import 'package:watch_together/src/state/settings.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

// Anime4K v4.0.1 md/Template/GLSL_Mac_Linux_{High,Low}-end/input.conf,
// Ctrl+1..6, with "~~/shaders/" stripped.
const _high = [
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_VL.glsl:Anime4K_Upscale_CNN_x2_VL.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_Soft_VL.glsl:Anime4K_Upscale_CNN_x2_VL.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Upscale_Denoise_CNN_x2_VL.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_VL.glsl:Anime4K_Upscale_CNN_x2_VL.glsl:Anime4K_Restore_CNN_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_Soft_VL.glsl:Anime4K_Upscale_CNN_x2_VL.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Restore_CNN_Soft_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Upscale_Denoise_CNN_x2_VL.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Restore_CNN_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl',
];
const _low = [
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_Soft_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Upscale_Denoise_CNN_x2_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl:Anime4K_Restore_CNN_S.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Restore_CNN_Soft_M.glsl:Anime4K_Upscale_CNN_x2_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Restore_CNN_Soft_S.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Clamp_Highlights.glsl:Anime4K_Upscale_Denoise_CNN_x2_M.glsl:Anime4K_AutoDownscalePre_x2.glsl:Anime4K_AutoDownscalePre_x4.glsl:Anime4K_Restore_CNN_S.glsl:Anime4K_Upscale_CNN_x2_S.glsl',
];

Directory _fresh(String name) {
  final d = Directory('$_tmp/$name');
  if (d.existsSync()) d.deleteSync(recursive: true);
  return d..createSync(recursive: true);
}

void main() {
  test('presets match the Anime4K mpv templates file for file', () {
    for (final (i, mode) in ShaderPreset.modes.indexed) {
      expect(anime4kFiles(mode, ShaderQuality.hq).join(':'), _high[i],
          reason: '${mode.label} HQ');
      expect(anime4kFiles(mode, ShaderQuality.fast).join(':'), _low[i],
          reason: '${mode.label} Fast');
    }
    expect(anime4kFiles(ShaderPreset.off, ShaderQuality.hq), isEmpty);
    expect(anime4kFiles(ShaderPreset.custom, ShaderQuality.fast), isEmpty);
    expect(shaderLabel(ShaderPreset.a, ShaderQuality.hq), 'Mode A (HQ)');
    expect(shaderLabel(ShaderPreset.ca, ShaderQuality.fast), 'Mode C+A (Fast)');
    expect(shaderLabel(ShaderPreset.off, ShaderQuality.fast), 'Off');
  });

  test('the asset dir ships exactly the files the presets need', () {
    final shipped = Directory(anime4kAssetDir)
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.endsWith('.glsl'))
        .toList()
      ..sort();
    expect(shipped, anime4kAllFiles);
    expect(File('$anime4kAssetDir/LICENSE').readAsStringSync(),
        contains('MIT License'));
  });

  test('path list separator per platform', () {
    expect(shaderListSeparator(windows: false), ':');
    expect(shaderListSeparator(windows: true), ';');
    expect(joinShaderPaths(['/a/x.glsl', '/b/y.glsl'], windows: false),
        '/a/x.glsl:/b/y.glsl');
    expect(joinShaderPaths([r'C:\s\x.glsl', r'D:\y.glsl'], windows: true),
        r'C:\s\x.glsl;D:\y.glsl');
    expect(joinShaderPaths([], windows: false), '');
  });

  test('path problems: missing file, separator inside a path', () {
    final d = _fresh('shaders_problem');
    final ok = File('${d.path}/ok.glsl')..writeAsStringSync('//');
    final colon = File('${d.path}/a:b.glsl')..writeAsStringSync('//');
    expect(shaderPathsProblem([ok.path], windows: false), isNull);
    expect(shaderPathsProblem([ok.path, '${d.path}/gone.glsl'], windows: false),
        '"gone.glsl" not found');
    expect(shaderPathsProblem([colon.path], windows: false), contains('":"'));
    expect(shaderPathsProblem([colon.path], windows: true), isNull);
  });

  group('asset extraction', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('copies the bundle once per version, redoes a broken copy', () async {
      final support = _fresh('shaders_support');
      final dir = await extractAnime4k(support);
      expect(dir.path, endsWith('shaders/anime4k-$anime4kVersion'));
      for (final f in [...anime4kAllFiles, 'LICENSE']) {
        expect(File('${dir.path}/$f').readAsBytesSync(),
            File('$anime4kAssetDir/$f').readAsBytesSync(),
            reason: f);
      }
      // Second run is a no-op: a marker-tagged copy stays untouched.
      final probe = File('${dir.path}/${anime4kAllFiles.first}')
        ..writeAsStringSync('touched');
      await extractAnime4k(support);
      expect(probe.readAsStringSync(), 'touched');
      // A missing file means a broken copy: everything is rewritten.
      File('${dir.path}/${anime4kAllFiles.last}').deleteSync();
      await extractAnime4k(support);
      expect(File('${dir.path}/${anime4kAllFiles.last}').existsSync(), isTrue);
      expect(probe.readAsStringSync(), isNot('touched'));

      shaderSupportDir = () async => support;
      final paths =
          await shaderPathsFor(ShaderPreset.b, ShaderQuality.fast, const []);
      expect(paths.map((p) => p.split('/').last).join(':'), _low[1]);
      expect(shaderPathsProblem(paths), isNull);
      expect(await shaderPathsFor(ShaderPreset.off, ShaderQuality.hq, ['/x']),
          isEmpty);
      expect(await shaderPathsFor(ShaderPreset.custom, ShaderQuality.hq, ['/x']),
          ['/x']);
    });
  });

  test('shader settings persist across a reload', () async {
    Hive.init(_fresh('shaders_hive').path);
    final a = AppSettings();
    await a.ensureLoaded();
    expect(a.shaderPreset.value, ShaderPreset.off);
    expect(a.shaderQuality.value, ShaderQuality.hq);
    expect(a.customShaders.value, isEmpty);
    a.setShaderPreset(ShaderPreset.bb);
    a.setShaderQuality(ShaderQuality.fast);
    a.setCustomShaders(['/s/one.glsl', '/s/two.glsl']);
    await Future.delayed(const Duration(milliseconds: 100));
    await Hive.close();

    final b = AppSettings();
    await b.ensureLoaded();
    expect(b.shaderPreset.value, ShaderPreset.bb);
    expect(b.shaderQuality.value, ShaderQuality.fast);
    expect(b.customShaders.value, ['/s/one.glsl', '/s/two.glsl']);
    await Hive.close();
  });
}
