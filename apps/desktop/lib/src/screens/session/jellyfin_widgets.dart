import 'package:flutter/material.dart';

import '../../jellyfin/session_media.dart';
import 'player_controls.dart' show FloatingPill;

// Jellyfin pieces of the session player. Plain widgets fed by the
// coordinator's signals, so tests can pump them without the player.

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
