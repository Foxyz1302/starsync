import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sync_relay_core/core.dart';

Future<String> encodeAvatar(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final file = File(trimmed);
  if (!await file.exists()) {
    throw const FormatException('avatar file not found — check the path or pick again with Browse');
  }
  late final List<int> raw;
  try {
    raw = await file.readAsBytes();
  } catch (_) {
    throw const FormatException('could not read that avatar file — pick it again with Browse');
  }
  if (raw.isEmpty) {
    throw const FormatException('that avatar file is empty — pick a PNG, JPG or WebP photo');
  }
  final decoded = img.decodeImage(Uint8List.fromList(raw));
  if (decoded == null) {
    throw const FormatException('could not read that image — pick a PNG, JPG or WebP photo');
  }
  final resized = img.copyResize(
    decoded,
    width: 128,
    height: 128,
    maintainAspect: true,
    backgroundColor: img.PixelUndefined(),
    interpolation: img.Interpolation.cubic,
  );
  final png = img.encodePng(resized);
  final b64 = base64Encode(png);
  if (b64.length > RelayConstants.maxAvatarBytes) {
    throw const FormatException('that photo is still too large after shrinking — pick a smaller one');
  }
  return b64;
}
