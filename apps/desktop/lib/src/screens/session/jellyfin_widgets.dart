import 'package:flutter/material.dart';

import '../../jellyfin/session_media.dart';
import '../../session/session_coordinator.dart' show AutoAdvance, autoAdvanceSecs;
import '../../widgets/app_menu.dart' show AppGlass;
import 'player_controls.dart' show FloatingPill;

// Jellyfin pieces of the session player. Plain widgets fed by the
// coordinator's signals, so tests can pump them without the player.

/// Previous / next episode in the video controls. Nothing when there is
/// no such episode or this viewer cannot put it up (no account).
class EpisodeSkipButton extends StatelessWidget {
  final EpisodeLink? episode;
  final bool next;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  const EpisodeSkipButton(
      {super.key, required this.episode, required this.next, required this.onPressed, this.focusNode});

  @override
  Widget build(BuildContext context) {
    final e = episode;
    if (e == null) return const SizedBox.shrink();
    return Tooltip(
      message: '${next ? 'Next' : 'Previous'}: ${e.label}  (${next ? '> or Shift+N' : '< or Shift+P'})',
      child: IconButton(
        key: ValueKey(next ? 'episode-next' : 'episode-previous'),
        focusNode: focusNode,
        color: Colors.white,
        iconSize: 22,
        visualDensity: VisualDensity.compact,
        icon: Icon(next ? Icons.skip_next_rounded : Icons.skip_previous_rounded),
        onPressed: onPressed,
      ),
    );
  }
}

/// Floating "Next episode ›" from the ED (or the last two minutes), while
/// the controls are up (`PillGate`): faint at rest, lit on hover.
class NextEpisodePill extends StatelessWidget {
  final EpisodeLink episode;
  final VoidCallback onPressed;
  const NextEpisodePill({super.key, required this.episode, required this.onPressed});

  @override
  Widget build(BuildContext context) => FloatingPill(
        label: 'Next episode',
        tooltip: 'Next: ${episode.label}',
        tapKey: const ValueKey('next-episode-pill'),
        onPressed: onPressed,
      );
}

/// At the end of an episode: "Next: S1E7 title" with Play now, and while
/// the auto-advance countdown runs, the seconds left and Cancel.
class EndOfEpisodeCard extends StatelessWidget {
  final EpisodeLink next;
  final AutoAdvance? countdown;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;
  const EndOfEpisodeCard({
    super.key,
    required this.next,
    required this.countdown,
    required this.onPlayNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final c = countdown;
    // The same card as Up next's (`UpNextCard`): the app's glass, 400 wide.
    return AppGlass(
      key: const ValueKey('end-of-episode'),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(c == null ? 'Up next' : 'Next episode in ${c.secondsLeft} s',
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 2),
              Text('Next: ${next.label}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.25)),
              if (c != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: c.secondsLeft / autoAdvanceSecs),
                    duration: const Duration(seconds: 1),
                    builder: (context, v, _) =>
                        LinearProgressIndicator(value: v, minHeight: 3, backgroundColor: const Color(0x1FFFFFFF)),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (c != null)
                    TextButton(
                        key: const ValueKey('auto-advance-cancel'),
                        onPressed: onCancel,
                        child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('play-next'),
                    onPressed: onPlayNow,
                    icon: const Icon(Icons.skip_next_rounded, size: 18),
                    label: Text(c == null ? 'Play next' : 'Play now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// This viewer cannot play the Jellyfin media: say why and offer to link
/// an account (never a silent stall).
class JellyfinBlockedCard extends StatelessWidget {
  final BlockedPlay blocked;
  final VoidCallback onLinkAccount;
  final VoidCallback onRetry;
  const JellyfinBlockedCard(
      {super.key, required this.blocked, required this.onLinkAccount, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('jellyfin-blocked'),
      color: Colors.black.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: Colors.orange, size: 32),
              const SizedBox(height: 10),
              Text(blocked.message, textAlign: TextAlign.center, style: t.titleSmall),
              const SizedBox(height: 6),
              Text(
                  'Whoever put it up passes it on automatically while their app is open; '
                  'if they left, ask them to put it up again. Or link your own account in Integrations.',
                  textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                      key: const ValueKey('link-jellyfin-account'),
                      onPressed: onLinkAccount,
                      child: const Text('Link a Jellyfin account')),
                  TextButton(onPressed: onRetry, child: const Text('Try again')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
