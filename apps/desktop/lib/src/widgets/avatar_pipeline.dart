import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sync_relay_core/core.dart';

/// An image file shrunk to 128 px as base64 PNG ('' for an empty path).
/// Throws [FormatException] with a user-facing message.
Future<String> encodeAvatar(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final file = File(trimmed);
  if (!await file.exists()) {
    throw const FormatException('avatar file not found — pick it again');
  }
  late final List<int> raw;
  try {
    raw = await file.readAsBytes();
  } catch (_) {
    throw const FormatException('could not read that avatar file — pick it again');
  }
  if (raw.isEmpty) {
    throw const FormatException('that avatar file is empty — pick a PNG, JPG or WebP photo');
  }
  return encodeAvatarBytes(Uint8List.fromList(raw));
}

/// Any image's bytes shrunk to 128 px as base64 PNG.
String encodeAvatarBytes(Uint8List raw) {
  final decoded = img.decodeImage(raw);
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
  final b64 = base64Encode(img.encodePng(resized));
  if (b64.length > RelayConstants.maxAvatarBytes) {
    throw const FormatException('that photo is still too large after shrinking — pick a smaller one');
  }
  return b64;
}

/// The profile's cropped PNG as sent to the server: as is when it fits
/// the cap, else shrunk like [encodeAvatarBytes].
String avatarWireBase64(Uint8List png) {
  final b64 = base64Encode(png);
  return b64.length <= RelayConstants.maxAvatarBytes ? b64 : encodeAvatarBytes(png);
}
