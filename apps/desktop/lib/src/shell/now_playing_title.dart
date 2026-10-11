import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/now_playing.dart';
import '../state/session_state.dart';
import 'motion.dart';

/// Tests: art bytes by hash instead of the session's cache.
@visibleForTesting
Uint8List? Function(String hash)? debugArtBytes;

/// The one lookup for media art (cover, banner) by content hash: null
/// when there is none or it has not arrived yet (listeners of
/// [artChanges] hear when it lands).
Uint8List? artBytes(String hash) {
  if (hash.isEmpty) return null;
  final debug = debugArtBytes;
  if (debug != null) return debug(hash);
  return SessionState.instance.coordinator.art.bytesFor(hash);
}

/// Notifies when art arrives.
Listenable artChanges() => SessionState.instance.coordinator.art;

final _images = <String, MemoryImage>{};

/// [hash]'s art as an image, the same provider while the bytes are the
/// same (so a rebuild never decodes again).
ImageProvider? artImage(String hash) {
  final bytes = artBytes(hash);
  if (bytes == null) return null;
  final hit = _images[hash];
  if (hit != null && identical(hit.bytes, bytes)) return hit;
  if (_images.length > 16) _images.clear();
  return _images[hash] = MemoryImage(bytes);
}

/// [image] fading in (ease) once decoded; nothing before.
Widget fadeInImage(ImageProvider image, {BoxFit fit = BoxFit.cover}) => Image(
      image: image,
      fit: fit,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: easeTime, curve: ease, child: child),
    );

/// The portrait cover (2:3) of the current media, a quiet tile with a
/// film icon until (or unless) its art arrives; [wide] (a video
/// thumbnail): 16:9 at the same height.
class ArtCover extends StatelessWidget {
  final String hash;
  final double width;
  final bool wide;
  const ArtCover({super.key, required this.hash, this.width = 40, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final image = artImage(hash);
    final r = BorderRadius.circular(width >= 80 ? 10 : 6);
    return Container(
      width: wide ? width * 1.5 * 16 / 9 : width,
      height: width * 1.5,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2A2D35), Color(0xFF17191E)],
                ),
              ),
              child: Icon(Icons.movie_outlined, color: Colors.white38, size: width * 0.45),
            ),
            if (image != null) fadeInImage(image),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: r,
                border: Border.all(color: Colors.white12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _shadow = [Shadow(color: Color(0x99000000), blurRadius: 8)];

/// Title and episode line of [now] (with its cover unless [cover] is
/// off), ellipsized; cross-fades when the media changes.
class NowPlayingBlock extends StatelessWidget {
  final NowPlaying? now;
  final bool cover;
  /// Smaller type (the mini player).
  final bool compact;
  const NowPlayingBlock({super.key, required this.now, this.cover = true, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final n = now;
    final Widget child;
    if (n == null) {
      child = const SizedBox.shrink(key: ValueKey('now-playing-none'));
    } else {
      final episode = n.episode;
      child = Row(
        key: ValueKey('now-playing:${n.title}\n${episode ?? ''}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cover) ...[ArtCover(hash: n.posterHash, wide: n.thumbnail), const SizedBox(width: 12)],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.title,
                  key: const ValueKey('now-playing-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: compact ? 13 : 16,
                      shadows: _shadow),
                ),
                if (episode != null && episode.isNotEmpty)
                  Text(
                    episode,
                    key: const ValueKey('now-playing-episode'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white70, fontSize: compact ? 11 : 13, shadows: _shadow),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return fadeThrough(child, expand: false, alignment: AlignmentDirectional.centerStart);
  }
}

/// [NowPlayingBlock] of the session's current media.
class NowPlayingTitle extends StatelessWidget {
  final bool cover;
  final bool compact;
  const NowPlayingTitle({super.key, this.cover = true, this.compact = false});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: artChanges(),
        builder: (context, _) => SignalBuilder(
          builder: (context) => NowPlayingBlock(
            now: SessionState.instance.coordinator.nowPlaying.value,
            cover: cover,
            compact: compact,
          ),
        ),
      );
}
