import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../jellyfin/session_media.dart';
import '../../jellyfin/track_prefs.dart';
import '../../session/session_coordinator.dart' show AutoAdvance, autoAdvanceSecs;

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

/// Floating "Next episode ›" near the end of an episode: faint at rest,
/// lit on hover. Lives outside the auto-hiding controls, so it shows in
/// fullscreen and with the controls hidden.
class NextEpisodePill extends StatefulWidget {
  final EpisodeLink episode;
  final VoidCallback onPressed;
  const NextEpisodePill({super.key, required this.episode, required this.onPressed});

  @override
  State<NextEpisodePill> createState() => _NextEpisodePillState();
}

class _NextEpisodePillState extends State<NextEpisodePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: 'Next: ${widget.episode.label}',
        child: AnimatedScale(
          duration: const Duration(milliseconds: 150),
          scale: _hover ? 1.06 : 1,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _hover ? 1 : 0.45,
            child: GestureDetector(
              key: const ValueKey('next-episode-pill'),
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _hover ? primary : Colors.white24),
                  boxShadow: _hover
                      ? [BoxShadow(color: primary.withValues(alpha: 0.45), blurRadius: 16)]
                      : const [],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Next episode', style: TextStyle(color: Colors.white, fontSize: 13)),
                    SizedBox(width: 4),
                    Icon(Icons.chevron_right, color: Colors.white, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

/// A track pick from [TracksControlButton]: audio id, subtitle id, or off.
typedef TrackPick = ({int? aid, int? sid, bool subtitlesOff});

/// Audio / subtitle menu for the controls bar. The choice is remembered
/// for the next Jellyfin item (per viewer).
class TracksControlButton extends StatelessWidget {
  final FocusNode? focusNode;
  final List<MpvTrack> Function() tracks;
  final Future<({int? aid, int? sid})> Function() current;
  final void Function(TrackPick pick) onPick;
  final ValueChanged<bool>? onMenuOpen;
  const TracksControlButton({
    super.key,
    this.focusNode,
    required this.tracks,
    required this.current,
    required this.onPick,
    this.onMenuOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Audio and subtitles',
      child: IconButton(
        key: const ValueKey('tracks-button'),
        focusNode: focusNode,
        color: Colors.white,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.subtitles_outlined),
        onPressed: () => _open(context),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final list = tracks();
    final button = context.findRenderObject() as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final navigator = Navigator.of(context);
    final now = await current();
    if (!navigator.mounted) return;
    final audio = list.where((t) => t.type == JellyfinStreamType.audio).toList();
    final subs = list.where((t) => t.type == JellyfinStreamType.subtitle).toList();
    PopupMenuItem<TrackPick> header(String text) => PopupMenuItem(
        enabled: false,
        height: 28,
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)));
    onMenuOpen?.call(true);
    final pick = await showMenu<TrackPick>(
      context: navigator.context,
      position: position,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
      items: [
        header('Audio'),
        if (audio.isEmpty)
          const PopupMenuItem(enabled: false, height: 32, child: Text('None')),
        for (final t in audio)
          CheckedPopupMenuItem(
            value: (aid: t.id, sid: null, subtitlesOff: false),
            checked: now.aid == t.id,
            height: 36,
            child: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        const PopupMenuDivider(),
        header('Subtitles'),
        CheckedPopupMenuItem(
          value: (aid: null, sid: null, subtitlesOff: true),
          checked: now.sid == null,
          height: 36,
          child: const Text('Off'),
        ),
        for (final t in subs)
          CheckedPopupMenuItem(
            value: (aid: null, sid: t.id, subtitlesOff: false),
            checked: now.sid == t.id,
            height: 36,
            child: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
    onMenuOpen?.call(false);
    if (pick != null) onPick(pick);
  }
}
