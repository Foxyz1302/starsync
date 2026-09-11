import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

Future<String> encodeAvatar(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final file = File(trimmed);
  if (!await file.exists()) {
    throw const FormatException(
        'avatar file not found — check the path or pick again with Browse');
  }
  late final List<int> raw;
  try {
    raw = await file.readAsBytes();
  } catch (_) {
    throw const FormatException(
        'could not read that avatar file — pick it again with Browse');
  }
  if (raw.isEmpty) {
    throw const FormatException(
        'that avatar file is empty — pick a PNG, JPG or WebP photo');
  }
  final decoded = img.decodeImage(Uint8List.fromList(raw));
  if (decoded == null) {
    throw const FormatException(
        'could not read that image — pick a PNG, JPG or WebP photo');
  }
  final side =
      decoded.width < decoded.height ? decoded.width : decoded.height;
  final x = (decoded.width - side) ~/ 2;
  final y = (decoded.height - side) ~/ 2;
  final cropped =
      img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  final resized = img.copyResize(cropped, width: 128, height: 128);
  final jpg = img.encodeJpg(resized, quality: 85);
  if (jpg.length > 64 * 1024) {
    throw const FormatException(
        'that photo is still too large after shrinking — pick a smaller one');
  }
  return base64Encode(jpg);
}
