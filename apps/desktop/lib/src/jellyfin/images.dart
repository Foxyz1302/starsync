import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

/// Server-side scale steps: nearby sizes share one URL (and one cache
/// entry) instead of fetching per-pixel variants on every resize.
const _widthSteps = [160, 240, 320, 480, 640, 960, 1280, 1920, 2560];

int imageWidthStep(double physicalWidth) {
  for (final s in _widthSteps) {
    if (s >= physicalWidth) return s;
  }
  return _widthSteps.last;
}

/// A Jellyfin image sized to its box. The URL carries the image tag and the
/// width step, so Flutter's image cache (keyed by URL) reuses it until the
/// image changes on the server; decode is capped at the same width. Shows
/// [placeholder] (or a tinted box with [icon]) while loading and on error,
/// and fades in when ready.
class JellyfinImage extends StatelessWidget {
  final JellyfinClient client;
  final JellyfinImageRef? image;
  final BoxFit fit;
  final IconData icon;
  final Alignment alignment;
  final Widget? placeholder;
  const JellyfinImage({
    super.key,
    required this.client,
    required this.image,
    this.fit = BoxFit.cover,
    this.icon = Icons.movie_outlined,
    this.alignment = Alignment.center,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    final ref = image;
    final fallback = placeholder ?? _Placeholder(icon: icon);
    if (ref == null) return fallback;
    return LayoutBuilder(builder: (context, box) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
      final w = box.hasBoundedWidth ? box.maxWidth : 480.0;
      final step = imageWidthStep(w * dpr);
      final url = client.imageUrl(ref, maxWidth: step, quality: 85).toString();
      return Image.network(
        url,
        key: ValueKey(url),
        fit: fit,
        alignment: alignment,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: step,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) {
          if (sync) return child;
          return Stack(fit: StackFit.passthrough, children: [
            if (frame == null) fallback,
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: child,
            ),
          ]);
        },
        errorBuilder: (context, _, _) => fallback,
      );
    });
  }
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  const _Placeholder({required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: Icon(icon, size: 28, color: scheme.onSurfaceVariant.withValues(alpha: 0.35)),
      ),
    );
  }
}
