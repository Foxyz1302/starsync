import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../playback/frame_watchdog.dart';

/// Fingerprints what the compositor really shows of the video. Place
/// [anchor] in the video controls (built in the window and again in the
/// fullscreen route); [sample] captures the route around the newest
/// mounted anchor at ~200 px wide — the texture included — and hashes its
/// centre. This is the only per-presented-frame signal: mpv's own
/// counters keep ticking when the Flutter texture is stuck.
class ShownFrameProbe {
  final _anchors = <_AnchorState>[];

  Widget anchor() => _Anchor(probe: this);

  Future<int?> sample() async {
    for (final a in _anchors.reversed) {
      if (!a.mounted) continue;
      final boundary = a.context.findAncestorRenderObjectOfType<RenderRepaintBoundary>();
      if (boundary == null || !boundary.attached || !boundary.hasSize) return null;
      final width = boundary.size.width;
      if (width <= 0) return null;
      ui.Image? image;
      try {
        image = await boundary.toImage(pixelRatio: (200 / width).clamp(0.02, 1.0));
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return null;
        return hashCenterPixels(data, image.width, image.height);
      } catch (_) {
        // Route not painted (covered) or mid-teardown: no reading.
        return null;
      } finally {
        image?.dispose();
      }
    }
    return null;
  }
}

class _Anchor extends StatefulWidget {
  final ShownFrameProbe probe;
  const _Anchor({required this.probe});

  @override
  State<_Anchor> createState() => _AnchorState();
}

class _AnchorState extends State<_Anchor> {
  @override
  void initState() {
    super.initState();
    widget.probe._anchors.add(this);
  }

  @override
  void dispose() {
    widget.probe._anchors.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
