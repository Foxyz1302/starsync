import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/session_coordinator.dart' show ToastItem;
import '../state/session_state.dart';
import '../state/settings.dart';
import 'avatar.dart';
import 'motion.dart';

/// One toast on screen: who (null = the app itself), what, and whether it
/// is on its way out.
class ShellToast {
  final int id;
  final AvatarInfo? who;
  final IconData? icon;
  final String text;
  final bool chat;
  bool leaving = false;
  ShellToast({required this.id, required this.text, this.who, this.icon, this.chat = false});
}

/// Splits a coordinator toast into who and what: feed and chat toasts
/// name their [ToastItem.actor] and start with it ("Bob joined", "Bob:
/// hi"); the rest are the app's.
ShellToast shellToastFor(ToastItem t, AvatarInfo Function(String name) avatar) {
  final n = t.actor;
  if (n == null || n.isEmpty) return ShellToast(id: t.id, text: t.text, icon: Icons.info_outline);
  if (t.text.startsWith('$n: ')) {
    return ShellToast(id: t.id, who: avatar(n), text: t.text.substring(n.length + 2), chat: true);
  }
  final rest = t.text.startsWith('$n ') ? t.text.substring(n.length + 1) : t.text;
  final icon = rest.startsWith('joined')
      ? Icons.login
      : rest.startsWith('left')
          ? Icons.logout
          : rest.startsWith('sat you out')
              ? Icons.bedtime
              : rest.startsWith('nudged')
                  ? Icons.notifications_active_outlined
                  : rest.startsWith('changed')
                      ? Icons.swap_horiz
                      : Icons.info_outline;
  return ShellToast(id: t.id, who: avatar(n), text: rest, icon: icon);
}

/// The coordinator's toasts as cards with avatars, bottom-left: each
/// slides in, stays [life], then slides out and collapses its gap. A click
/// on a chat toast opens the chat ([onOpenChat]); the rest let clicks
/// through. Chat toasts follow [AppSettings.chatPopups].
class PartyToasts extends StatefulWidget {
  final Duration life;
  final VoidCallback? onOpenChat;
  const PartyToasts({super.key, this.life = const Duration(seconds: 5), this.onOpenChat});

  @override
  State<PartyToasts> createState() => _PartyToastsState();
}

class _PartyToastsState extends State<PartyToasts> {
  final _shown = <ShellToast>[];
  final _timers = <Timer>[];
  Set<int> _seen = {};
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    final coord = SessionState.instance.coordinator;
    // What was there before this mounted is old news.
    _seen = {for (final t in coord.toasts.peek()) t.id};
    _stop = effect(() {
      final items = coord.toasts.value;
      final fresh = [for (final t in items) if (!_seen.contains(t.id)) t];
      _seen = {for (final t in items) t.id};
      if (fresh.isEmpty) return;
      // Only new toasts re-run this, not the party they mention.
      untracked(() {
        final playing = coord.serverState.value?.transport == 'playing';
        final popups = AppSettings.instance.chatPopups.value;
        for (final t in fresh) {
          final toast = shellToastFor(t, (n) => avatarForName(n, coord));
          // Chat per Settings → Notifications (it is in the chat either way).
          if (toast.chat && !popups.shows(playing: playing)) continue;
          _add(toast);
        }
      });
    });
  }

  void _add(ShellToast t) {
    // Not from inside the effect's build-time notification.
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(() => _shown.add(t));
      _timers.add(Timer(widget.life, () {
        if (mounted) setState(() => t.leaving = true);
      }));
      _timers.add(Timer(widget.life + easeTime, () {
        if (mounted) setState(() => _shown.remove(t));
      }));
    });
  }

  @override
  void dispose() {
    _stop();
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  void _open(ShellToast t) {
    widget.onOpenChat?.call();
    setState(() => t.leaving = true);
  }

  @override
  Widget build(BuildContext context) => ToastColumn(
        toasts: _shown.reversed.take(6).toList().reversed.toList(),
        onTap: widget.onOpenChat == null ? null : _open,
      );
}

class ToastColumn extends StatelessWidget {
  final List<ShellToast> toasts;
  /// Clicks on chat toasts; null (or any other toast): clicks pass through.
  final ValueChanged<ShellToast>? onTap;
  const ToastColumn({super.key, required this.toasts, this.onTap});

  Widget _card(ShellToast t) {
    final card = ToastCard(toast: t);
    final tap = onTap;
    if (!t.chat || tap == null || t.leaving) return IgnorePointer(child: card);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('toast-open-chat-${t.id}'),
        onTap: () => tap(t),
        child: card,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in toasts)
          TweenAnimationBuilder<double>(
            key: ValueKey(t.id),
            tween: Tween(begin: 0, end: 1),
            duration: easeTime,
            curve: ease,
            builder: (context, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(offset: Offset(-24 * (1 - v), 0), child: child),
            ),
            // Leaving: slide back out, fade, and collapse the gap it leaves.
            child: AnimatedAlign(
              duration: easeTime,
              curve: ease,
              alignment: Alignment.topLeft,
              heightFactor: t.leaving ? 0 : 1,
              child: AnimatedSlide(
                duration: easeTime,
                curve: ease,
                offset: t.leaving ? const Offset(-0.25, 0) : Offset.zero,
                child: AnimatedOpacity(
                  duration: easeTime,
                  curve: ease,
                  opacity: t.leaving ? 0 : 1,
                  child: Padding(padding: const EdgeInsets.only(top: 8), child: _card(t)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ToastCard extends StatelessWidget {
  final ShellToast toast;
  const ToastCard({super.key, required this.toast});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = toast.who;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: who == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (who != null)
                StatusAvatar(info: who, size: 38, badges: false)
              else
                CircleAvatar(
                  radius: 19,
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                  child: Icon(toast.icon ?? Icons.info_outline, size: 18, color: scheme.primary),
                ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (who != null) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(who.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                          ),
                          if (toast.icon != null) ...[
                            const SizedBox(width: 6),
                            Icon(toast.icon, size: 16, color: scheme.primary),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      toast.text,
                      style: TextStyle(
                        fontSize: toast.chat ? 15 : 14,
                        color: toast.chat || who == null ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
