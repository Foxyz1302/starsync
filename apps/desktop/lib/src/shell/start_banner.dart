import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/now_playing.dart';
import '../state/session_state.dart';
import 'motion.dart';
import 'now_playing_title.dart';

/// Space kept free at the bottom of the start card for the controls and
/// the status pill.
const startCardBottom = 176.0;

/// The start card of [now]: its banner (cover-fit, darkened), else a soft
/// blur of the cover, else dark; the cover, a big title and the episode
/// line bottom left, above the controls.
class StartCard extends StatelessWidget {
  final NowPlaying now;
  const StartCard({super.key, required this.now});

  @override
  Widget build(BuildContext context) {
    final banner = artImage(now.bannerHash);
    final cover = banner == null ? artImage(now.posterHash) : null;
    final episode = now.episode;
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      // Small (the mini player): no cover, a smaller title near the bottom.
      final small = h < 320;
      final coverWidth = (h * 0.26).clamp(84.0, 240.0) / 1.5;
      final titleSize = small ? (h * 0.08).clamp(13.0, 18.0) : (h * 0.05).clamp(22.0, 44.0);
      final side = small ? 12.0 : (box.maxWidth * 0.05).clamp(20.0, 72.0);
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF0C0D11)),
          if (banner != null)
            fadeInImage(banner)
          else if (cover != null)
            Opacity(
              opacity: 0.5,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48, tileMode: TileMode.decal),
                child: Transform.scale(scale: 1.3, child: fadeInImage(cover)),
              ),
            )
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.7, 0.5),
                  radius: 1.2,
                  colors: [Color(0xFF23262E), Color(0xFF0C0D11)],
                ),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.35, 1],
                colors: [Color(0x55000000), Color(0x22000000), Color(0xE6000000)],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                stops: [0, 0.65],
                colors: [Color(0x99000000), Color(0x00000000)],
              ),
            ),
          ),
          Positioned(
            left: side,
            right: side,
            bottom: small ? 12 : startCardBottom,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // A thumbnail already fills the card as the banner.
                if (!small && !now.thumbnail) ...[
                  ArtCover(hash: now.posterHash, width: coverWidth),
                  const SizedBox(width: 24),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        now.title,
                        key: const ValueKey('start-card-title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          shadows: const [Shadow(color: Color(0x99000000), blurRadius: 16)],
                        ),
                      ),
                      if (episode != null && episode.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          episode,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white70, fontSize: titleSize * 0.42),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// [StartCard] over the picture until playback starts on this media
/// (the server plays, or its position passed 1 s); then it fades out and
/// stays gone for that media, whatever happens later. Never takes input.
class StartBanner extends StatefulWidget {
  const StartBanner({super.key});

  @override
  State<StartBanner> createState() => _StartBannerState();
}

class _StartBannerState extends State<StartBanner> {
  int? _mediaId;
  bool _started = false;
  // Faded out: the card leaves the tree (and its images with it).
  bool _gone = true;
  NowPlaying? _last;

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: artChanges(),
        builder: (context, _) => SignalBuilder(builder: (context) {
          final r = coord.serverState.value;
          final now = coord.nowPlaying.value;
          if (r != null && r.mediaId != _mediaId) {
            _mediaId = r.mediaId;
            _started = false;
          }
          if (r != null && (r.transport == 'playing' || r.position >= 1)) _started = true;
          final show = now != null && r?.media != null && !_started;
          if (show) {
            _last = now;
            _gone = false;
          }
          final last = _last;
          if (last == null || _gone) return const SizedBox.shrink();
          return AnimatedOpacity(
            key: const ValueKey('start-banner'),
            opacity: show ? 1 : 0,
            duration: easeTime,
            curve: ease,
            onEnd: () {
              if (!show && mounted) setState(() => _gone = true);
            },
            child: StartCard(now: last),
          );
        }),
      ),
    );
  }
}
