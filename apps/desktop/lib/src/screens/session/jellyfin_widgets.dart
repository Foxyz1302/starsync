import 'package:flutter/material.dart';

import '../../jellyfin/session_media.dart';
import '../../session/session_coordinator.dart' show AutoAdvance, autoAdvanceSecs;
import 'player_controls.dart' show FloatingPill;

// Jellyfin pieces of the session screen. Plain widgets fed by the
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

/// Floating "Next episode ›" from the ED (or the last two minutes):
/// faint at rest, lit on hover. Lives outside the auto-hiding controls, so
/// it shows in fullscreen and with the controls hidden.
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
    final t = Theme.of(context).textTheme;
    final c = countdown;
    return Card(
      key: const ValueKey('end-of-episode'),
      color: Colors.black.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c == null ? 'Up next' : 'Next episode in ${c.secondsLeft} s',
                  style: t.labelLarge?.copyWith(color: Colors.white70)),
              const SizedBox(height: 4),
              Text('Next: ${next.label}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: t.titleMedium),
              if (c != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: c.secondsLeft / autoAdvanceSecs),
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
              Text('Link your own account in Integrations, or ask the host to relay it.',
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

/// Small member-list badge: plays the Jellyfin item through the host.
class ViaHostBadge extends StatelessWidget {
  const ViaHostBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'No Jellyfin account here: watches through the host',
      child: Container(
        key: const ValueKey('via-host'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: const Text('via host', style: TextStyle(fontSize: 10, color: Colors.white70)),
      ),
    );
  }
}
