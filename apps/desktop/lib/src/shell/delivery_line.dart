import 'package:flutter/material.dart';

import '../session/delivery.dart';
import 'motion.dart';

// The members card's view of [Delivery]: one source line on top, a buffer
// dot on each member. Nothing of it sits on the picture.

Color _tone(SourceState s, ColorScheme scheme) => switch (s) {
      SourceState.ok => scheme.primary,
      SourceState.slow || SourceState.waiting => Colors.amber,
      SourceState.left => Colors.redAccent.shade200,
    };

IconData _icon(Delivery d) => switch (d.state) {
      SourceState.left => Icons.link_off_rounded,
      SourceState.waiting => Icons.hourglass_top_rounded,
      _ => switch (d.kind) {
          DeliveryKind.memberRelay => Icons.cell_tower,
          DeliveryKind.serverFetch => Icons.cloud_download_outlined,
          DeliveryKind.hostFile => Icons.folder_shared_outlined,
          DeliveryKind.serverFile => Icons.dns_outlined,
          DeliveryKind.link => Icons.public,
          DeliveryKind.jellyfin => Icons.video_library_outlined,
        },
    };

/// Where the current media comes from and how it reaches the others:
/// "Foxyz passes it on through the server", "3 through the server ·
/// 4.1 MB/s, needs 2.3 MB/s" and a bar of the source's speed against the
/// video's (past the mark: keeping up). Amber when slow or waiting, red
/// when the source left.
class SourceLine extends StatelessWidget {
  final Delivery delivery;
  const SourceLine({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    final scheme = Theme.of(context).colorScheme;
    final tone = _tone(d.state, scheme);
    final detail = d.detail;
    final headroom = d.state == SourceState.left ? null : d.headroom;
    return Tooltip(
      message: d.explain,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        key: const ValueKey('source-line'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        decoration: BoxDecoration(
          color: d.state == SourceState.ok ? scheme.surfaceContainerHigh : tone.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(_icon(d), size: 18, color: tone),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(detail, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                  if (headroom != null) ...[
                    const SizedBox(height: 6),
                    _HeadroomBar(headroom: headroom, slow: d.state == SourceState.slow),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The source's speed on a scale to twice the video's bitrate; the mark
/// in the middle is what the video needs.
class _HeadroomBar extends StatelessWidget {
  final double headroom;
  final bool slow;
  const _HeadroomBar({required this.headroom, required this.slow});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = (headroom / 2).clamp(0.04, 1.0);
    final color = slow ? Colors.amber : Colors.greenAccent.shade400;
    return SizedBox(
      key: const ValueKey('headroom-bar'),
      height: 4,
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            AnimatedContainer(
              duration: easeTime,
              curve: ease,
              width: box.maxWidth * fill,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
            ),
            Positioned(
              left: box.maxWidth / 2 - 0.75,
              top: -1,
              bottom: -1,
              child: Container(width: 1.5, color: scheme.onSurface.withValues(alpha: 0.7)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A member's buffer at a glance: green enough to play on, amber low,
/// red empty while playing.
Color healthColor(BufferHealth h) => switch (h) {
      BufferHealth.good => Colors.greenAccent.shade400,
      BufferHealth.low => Colors.amber,
      BufferHealth.starving => Colors.redAccent.shade200,
    };

/// The members card's subtitle: [status] ("ready"), then how the member
/// gets the media (the source's own pill says it serves it), after a dot
/// coloured by its buffer; the hover says how much it has buffered.
class DeliveryStatus extends StatelessWidget {
  final String status;
  final MemberDelivery? delivery;
  const DeliveryStatus({super.key, required this.status, this.delivery});

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    final route = d == null || d.route == DeliveryRoute.source ? '' : d.short;
    final text = Text([status, if (route.isNotEmpty) route].join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis);
    if (d == null) return text;
    final health = d.health;
    return Tooltip(
      message: d.detail,
      waitDuration: const Duration(milliseconds: 400),
      child: Row(
        children: [
          if (health != null) ...[
            AnimatedContainer(
              key: const ValueKey('health-dot'),
              duration: easeTime,
              curve: ease,
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: healthColor(health), shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: text),
        ],
      ),
    );
  }
}
