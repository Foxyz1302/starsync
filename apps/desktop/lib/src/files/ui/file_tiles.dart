import 'dart:io';

import 'package:flutter/material.dart';

import 'package:sync_relay_core/core.dart';

import '../../shell/avatar.dart';
import 'thumb.dart';

// The Files page's rows and cards: an episode row (also used for Recent),
// a loose-video card, and the empty states.

/// What a play control is doing right now.
enum PlayState { idle, starting, playing }

/// Last path segment, ignoring trailing separators (`/media/anime/`).
String baseName(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Name of the folder [path] is in.
String parentName(String path) => baseName(File(path).parent.path);

/// Cleaned title of a loose video: `Title (2019)`.
String cleanTitle(ParsedName p) => p.year == null ? p.series : '${p.series} (${p.year})';

/// One file as a row: an episode on a show's page, or a Recent entry
/// ([indent] off).
class FileRow extends StatelessWidget {
  final String path;
  final String title;
  final String subtitle;
  /// Size text; null while unknown.
  final String? size;
  final PlayState state;
  final ThumbCache thumbs;
  /// Null disables the row.
  final VoidCallback? onTap;
  final bool indent;
  final Widget? trailing;
  const FileRow({
    super.key,
    required this.path,
    required this.title,
    required this.subtitle,
    required this.size,
    required this.state,
    required this.thumbs,
    required this.onTap,
    this.indent = true,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playing = state == PlayState.playing;
    final enabled = onTap != null;
    final muted = scheme.onSurfaceVariant;
    final icon = switch (state) {
      PlayState.starting => const SizedBox.square(
          dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      PlayState.playing => Icon(Icons.graphic_eq, size: 20, color: scheme.primary),
      PlayState.idle => Icon(Icons.play_circle_outline,
          size: 20, color: enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.38)),
    };
    return ThumbBuilder(
      cache: thumbs,
      path: path,
      builder: (context, t, _) {
        final duration = durationText(t);
        final meta = [?duration, ?size].join(' · ');
        return Material(
          color: playing ? scheme.primary.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: EdgeInsets.fromLTRB(indent ? 20 : 4, 5, 8, 5),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: ThumbImage(t, width: 80, height: 45),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(width: 20, child: Center(child: icon)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: playing ? scheme.primary : null,
                                ),
                              ),
                            ),
                            if (playing) ...[
                              const SizedBox(width: 8),
                              Pill('now playing', scheme.primary),
                            ],
                          ],
                        ),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontSize: 12)),
                      ],
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text(meta, style: TextStyle(color: muted, fontSize: 12)),
                  ],
                  ?trailing,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Text under a [VideoCard]'s 16:9 frame (title up to two lines, size).
const videoCardTextHeight = 66.0;

/// A loose video (movie, clip): 16:9 frame with its duration, then the
/// cleaned title and size.
class VideoCard extends StatelessWidget {
  final LocalEpisode video;
  final PlayState state;
  final ThumbCache thumbs;
  final VoidCallback? onTap;
  const VideoCard({
    super.key,
    required this.video,
    required this.state,
    required this.thumbs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playing = state == PlayState.playing;
    return ThumbBuilder(
      cache: thumbs,
      path: video.path,
      builder: (context, t, _) {
        final duration = durationText(t);
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: playing ? scheme.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ThumbImage(t),
                        if (duration != null)
                          Positioned(right: 6, bottom: 6, child: _Badge(duration)),
                        if (state != PlayState.idle)
                          Container(
                            color: Colors.black38,
                            alignment: Alignment.center,
                            child: state == PlayState.playing
                                ? const Icon(Icons.graphic_eq, color: Colors.white, size: 32)
                                : const SizedBox.square(
                                    dimension: 28,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 3, color: Colors.white)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  cleanTitle(video.parsed),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: playing ? scheme.primary : null,
                  ),
                ),
              ),
              Text(formatSize(video.file.size),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11)),
      );
}

class FilesEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;
  const FilesEmpty(this.icon, this.title, this.detail, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 60, bottom: 20),
      child: Column(
        children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(detail, style: TextStyle(color: scheme.onSurfaceVariant), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}
