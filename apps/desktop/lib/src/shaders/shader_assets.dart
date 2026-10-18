import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'shader_presets.dart';

const anime4kAssetDir = 'assets/shaders/anime4k';

/// The extracted copy's layout: bumped when [highpAnime4k] changes what
/// is written, so an older copy is written again.
const anime4kCopyRevision = 'hp1';

/// mpv needs real files: copies the shipped Anime4K shaders out of the
/// asset bundle into `<supportDir>/shaders/anime4k-<version>-<revision>`,
/// each made full precision on OpenGL ES ([highpAnime4k]), once per
/// version (a `.complete` marker is written last, so a cut-short copy is
/// redone). Returns that directory.
Future<Directory> extractAnime4k(
  Directory supportDir, {
  AssetBundle? bundle,
}) async {
  final dir = Directory(
      '${supportDir.path}${Platform.pathSeparator}shaders'
      '${Platform.pathSeparator}anime4k-$anime4kVersion-$anime4kCopyRevision');
  final marker = File('${dir.path}${Platform.pathSeparator}.complete');
  final files = anime4kAllFiles;
  if (await marker.exists() &&
      files.every((f) => File(_join(dir, f)).existsSync())) {
    return dir;
  }
  await dir.create(recursive: true);
  final b = bundle ?? rootBundle;
  for (final name in [...files, 'LICENSE']) {
    final data = await b.load('$anime4kAssetDir/$name');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(_join(dir, name)).writeAsBytes(
        name.endsWith('.glsl') ? utf8.encode(highpAnime4k(utf8.decode(bytes))) : bytes,
        flush: true);
  }
  await marker.writeAsString(anime4kVersion, flush: true);
  // Older copies (another version or revision) are not read again.
  try {
    await for (final e in dir.parent.list()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is Directory && name.startsWith('anime4k-') && e.path != dir.path) {
        await e.delete(recursive: true);
      }
    }
  } catch (_) {}
  return dir;
}

/// The name of the helper [highpAnime4k] adds to each pass.
const _hp = 'starsync_hp';

/// [glsl] (an Anime4K file) with its convolutions computed at full
/// precision on an OpenGL ES context, as they are on desktop OpenGL.
///
/// media_kit renders through OpenGL ES (EGL on Linux, ANGLE on Windows),
/// where mpv declares `precision mediump sampler2D`: a texture read is
/// mediump, and Anime4K's weights are bare literals, so every
/// `mat4(...) * go_0(...)` of a network ran at half precision (fp16 on
/// NVIDIA). The large (VL) networks overflow and round there: shifted
/// colours, posterised areas and a regular grid, worse once the
/// upscalers run at screen size. Each pass gets an identity function
/// with a highp parameter and result, and every `go_N` / `g_N` read goes
/// through it, so the products and sums that follow are highp. Desktop
/// GLSL ignores precision qualifiers, so nothing changes there. Anything
/// that is not such a read is left as it is.
String highpAnime4k(String glsl) {
  final read = RegExp(r'\b\w+_tex(?:Off)?\((?:[^()]|\([^()]*\))*\)');
  final define = RegExp(r'^#define g(?:o)?_\d+\b');
  final out = <String>[];
  var inHeader = false, helper = false;
  for (final line in const LineSplitter().convert(glsl)) {
    if (line.startsWith('//!')) {
      // A new pass starts at the first `//!` line after code.
      if (!inHeader) helper = false;
      inHeader = true;
      out.add(line);
      continue;
    }
    inHeader = false;
    if (define.hasMatch(line)) {
      if (!helper) {
        out.add('highp vec4 $_hp(highp vec4 v) { return v; }');
        helper = true;
      }
      out.add(line.replaceAllMapped(read, (m) => '$_hp(${m[0]})'));
      continue;
    }
    out.add(line);
  }
  return '${out.join('\n')}\n';
}

/// Absolute paths of [preset]'s Anime4K files inside [dir].
List<String> anime4kPaths(
        Directory dir, ShaderPreset preset, ShaderQuality quality) =>
    [for (final f in anime4kFiles(preset, quality)) _join(dir, f)];

String _join(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

/// Where the shipped shaders get extracted; swapped in tests.
Future<Directory> Function() shaderSupportDir = getApplicationSupportDirectory;

/// Absolute `glsl-shaders` entries for a choice, extracting the shipped
/// files first when needed. Empty for [ShaderPreset.off].
Future<List<String>> shaderPathsFor(
  ShaderPreset preset,
  ShaderQuality quality,
  List<String> custom,
) async {
  if (preset == ShaderPreset.off) return const [];
  if (preset == ShaderPreset.custom) return [...custom];
  final dir = await extractAnime4k(await shaderSupportDir());
  return anime4kPaths(dir, preset, quality);
}

/// Why [paths] can't go to mpv (a missing file, or a path holding the
/// list separator), or null when they can.
String? shaderPathsProblem(List<String> paths, {bool? windows}) {
  final sep = shaderListSeparator(windows: windows);
  for (final p in paths) {
    final name = p.split(RegExp(r'[/\\]')).last;
    // Windows drive letters ("C:\") are fine: there the separator is ';'.
    if (p.contains(sep)) return '"$name" has "$sep" in its path';
    if (!File(p).existsSync()) return '"$name" not found';
  }
  return null;
}
