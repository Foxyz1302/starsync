import 'dart:convert';

import 'package:flutter/material.dart';

class MemberAvatar extends StatelessWidget {
  final String avatarBase64;
  final String name;
  final double size;

  static final Map<String, MemoryImage> _images = {};

  const MemberAvatar({super.key, required this.avatarBase64, required this.name, this.size = 40});

  static MemoryImage? _providerFor(String raw) {
    if (raw.isEmpty) return null;
    var hit = _images[raw];
    if (hit != null) return hit;
    try {
      hit = MemoryImage(base64Decode(raw));
    } catch (_) {
      return null;
    }
    if (_images.length > 64) _images.clear();
    _images[raw] = hit;
    return hit;
  }

  @override
  Widget build(BuildContext context) {
    final image = _providerFor(avatarBase64);
    final decoration = BoxDecoration(shape: BoxShape.circle);
    if (image != null) {
      return Container(
        decoration: decoration,
        child: ClipOval(
          child: Image(
            image: image,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _fallback(),
          ),
        ),
      );
    }
    return Container(decoration: decoration, child: _fallback());
  }

  Widget _fallback() => CircleAvatar(
    radius: size / 2,
    backgroundColor: Colors.grey.shade800,
    child: Text(
      name.isEmpty ? '?' : name[0].toUpperCase(),
      style: TextStyle(fontSize: size * 0.4, color: Colors.white),
    ),
  );
}
