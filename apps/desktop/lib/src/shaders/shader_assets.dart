import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'shader_presets.dart';

const anime4kAssetDir = 'assets/shaders/anime4k';

/// mpv needs real files: copies the shipped Anime4K shaders out of the
/// asset bundle into `<supportDir>/shaders/anime4k-<version>`, once per
/// version (a `.complete` marker is written last, so a cut-short copy is
/// redone). Returns that directory.
Future<Directory> extractAnime4k(
  Directory supportDir, {
  AssetBundle? bundle,
}) async {
  final dir = Directory(
      '${supportDir.path}${Platform.pathSeparator}shaders'
      '${Platform.pathSeparator}anime4k-$anime4kVersion');
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
    await File(_join(dir, name)).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true);
  }
  await marker.writeAsString(anime4kVersion, flush: true);
  return dir;
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
