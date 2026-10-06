import 'dart:io';

// Anime4K v4.0.1 presets, file for file as in Anime4K's mpv templates
// (md/Template/GLSL_Mac_Linux_{High,Low}-end/input.conf): HQ = the
// high-end GPU set, Fast = the low-end set.

/// Anime4K release the shipped files come from (assets/shaders/anime4k).
const anime4kVersion = '4.0.1';

enum ShaderPreset {
  off('Off'),
  a('Mode A'),
  b('Mode B'),
  c('Mode C'),
  aa('Mode A+A'),
  bb('Mode B+B'),
  ca('Mode C+A'),
  custom('Custom shaders');

  final String label;
  const ShaderPreset(this.label);

  /// The six Anime4K modes, in Ctrl+1..Ctrl+6 order.
  static const modes = [a, b, c, aa, bb, ca];

  bool get isAnime4k => modes.contains(this);
}

enum ShaderQuality {
  hq('HQ'),
  fast('Fast');

  final String label;
  const ShaderQuality(this.label);
}

/// "Mode A (HQ)", "Off", "Custom shaders".
String shaderLabel(ShaderPreset preset, ShaderQuality quality) =>
    preset.isAnime4k ? '${preset.label} (${quality.label})' : preset.label;

const _clamp = 'Anime4K_Clamp_Highlights.glsl';
const _down = [
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
];

/// Anime4K file names of [preset] in mpv order; empty for off/custom.
List<String> anime4kFiles(ShaderPreset preset, ShaderQuality quality) {
  final hq = quality == ShaderQuality.hq;
  // Big/small network sizes: HQ uses VL then M, Fast uses M then S.
  final big = hq ? 'VL' : 'M';
  final small = hq ? 'M' : 'S';
  String restore(String size) => 'Anime4K_Restore_CNN_$size.glsl';
  String soft(String size) => 'Anime4K_Restore_CNN_Soft_$size.glsl';
  String up(String size) => 'Anime4K_Upscale_CNN_x2_$size.glsl';
  String denoise(String size) => 'Anime4K_Upscale_Denoise_CNN_x2_$size.glsl';
  return switch (preset) {
    ShaderPreset.off || ShaderPreset.custom => const [],
    ShaderPreset.a => [_clamp, restore(big), up(big), ..._down, up(small)],
    ShaderPreset.b => [_clamp, soft(big), up(big), ..._down, up(small)],
    ShaderPreset.c => [_clamp, denoise(big), ..._down, up(small)],
    ShaderPreset.aa => [
        _clamp, restore(big), up(big), restore(small), ..._down, up(small)
      ],
    ShaderPreset.bb => [
        _clamp, soft(big), up(big), ..._down, soft(small), up(small)
      ],
    ShaderPreset.ca => [
        _clamp, denoise(big), ..._down, restore(small), up(small)
      ],
  };
}

/// Every file some preset needs: exactly what assets/shaders/anime4k holds.
List<String> get anime4kAllFiles => {
      for (final p in ShaderPreset.modes)
        for (final q in ShaderQuality.values) ...anime4kFiles(p, q),
    }.toList()
      ..sort();

/// mpv's path-list separator: ';' on Windows, ':' elsewhere.
String shaderListSeparator({bool? windows}) =>
    (windows ?? Platform.isWindows) ? ';' : ':';

/// The `glsl-shaders` value for [paths].
String joinShaderPaths(List<String> paths, {bool? windows}) =>
    paths.join(shaderListSeparator(windows: windows));
