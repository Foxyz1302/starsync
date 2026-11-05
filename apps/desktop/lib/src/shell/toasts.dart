import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/session_coordinator.dart' show ToastItem;
import '../app/app_graph.dart';
import 'avatar.dart';
import 'motion.dart';
import 'person_card.dart' show PersonHover, PersonRef;

/// One toast on screen: who (null = the app itself), what, a picture
/// (an Up next item's), and whether it is on its way out.
class ShellToast {
  final int id;
  final AvatarInfo? who;
  final IconData? icon;
  final String text;
  final bool chat;
  final String thumb;
  /// Its own picture (a screenshot's) and click ([ToastItem]).
  final Uint8List? picture;
  final VoidCallback? onTap;
  bool leaving = false;
  ShellToast(
      {required this.id,
      required this.text,
      this.who,
      this.icon,
      this.chat = false,
      this.thumb = '',
      this.picture,
      this.onTap});
}

/// Splits a Notifier toast into who and what: feed and chat toasts name
/// their [ToastItem.actor] and start with it ("Bob joined", "Bob: hi");
/// the rest are the app's.
ShellToast shellToastFor(ToastItem t, AvatarInfo Function(String name) avatar) {
  final n = t.actor;
  if (n == null || n.isEmpty) {
    return ShellToast(
        id: t.id, text: t.text, icon: Icons.info_outline, thumb: t.thumb, picture: t.picture, onTap: t.onTap);
  }
  if (t.chat && t.text.startsWith('$n: ')) {
    return ShellToast(id: t.id, who: avatar(n), text: t.text.substring(n.length + 2), chat: true);
  }
  final rest = t.text.startsWith('$n ') ? t.text.substring(n.length + 1) : t.text;
  final icon = rest.startsWith('joined')
      ? Icons.login
      : rest.startsWith('left')
          ? Icons.logout
          : rest.startsWith('lost connection')
              ? Icons.wifi_off_rounded
              : rest.startsWith('is back')
                  ? Icons.wifi_rounded
                  : rest.startsWith('sat you out')
                      ? Icons.bedtime
                      : rest.startsWith('nudged')
                          ? Icons.notifications_active_outlined
                          : rest.startsWith('changed')
                              ? Icons.swap_horiz
                              : rest.startsWith('added')
                                  ? Icons.playlist_add_rounded
                                  : Icons.info_outline;
  return ShellToast(id: t.id, who: avatar(n), text: rest, icon: icon, thumb: t.thumb);
}

/// The Notifier's toasts as cards with avatars, bottom-left: each slides
/// in, stays while the Notifier keeps it (it drops it after its time),
/// then slides out and collapses its gap. A click on a chat toast opens
/// the chat ([onOpenChat]), one with its own action (a screenshot's: edit
/// it) runs that; the rest let clicks through. What pops up at
/// all (chat pop-ups, out, alone) is the Notifier's policy.
class PartyToasts extends StatefulWidget {
  final VoidCallback? onOpenChat;

  /// Toasts shown another way (flying as danmaku, your quick chat echo):
  /// left out when they come.
  final bool Function(ToastItem t)? skip;
  const PartyToasts({super.key, this.onOpenChat, this.skip});

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
    final coord = AppScope.of(context).coordinator;
    // What was there before this mounted is old news.
    _seen = {for (final t in coord.toasts.peek()) t.id};
    _stop = effect(() {
      final items = coord.toasts.value;
      final ids = {for (final t in items) t.id};
      final fresh = [for (final t in items) if (!_seen.contains(t.id)) t];
      final gone = _seen.difference(ids);
      _seen = ids;
      if (fresh.isEmpty && gone.isEmpty) return;
      // Only new toasts re-run this, not the party they mention.
      untracked(() {
        for (final t in fresh) {
          if (widget.skip?.call(t) ?? false) continue;
          _add(shellToastFor(t, (n) => avatarForName(n, coord, t.actorId)));
        }
        if (gone.isNotEmpty) _leave(gone);
      });
    });
  }

  void _add(ShellToast t) {
    // Not from inside the effect's build-time notification.
    scheduleMicrotask(() {
      if (mounted) setState(() => _shown.add(t));
    });
  }

  void _leave(Set<int> ids) {
    scheduleMicrotask(() {
      if (!mounted) return;
      final leaving = [for (final t in _shown) if (ids.contains(t.id) && !t.leaving) t];
      if (leaving.isEmpty) return;
      setState(() {
        for (final t in leaving) {
          t.leaving = true;
        }
      });
      _timers.add(Timer(easeTime, () {
        if (mounted) setState(() => _shown.removeWhere(leaving.contains));
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
    if (t.onTap case final tap?) {
      tap();
    } else {
      widget.onOpenChat?.call();
    }
    AppScope.of(context).notifier.dismiss(t.id);
  }

  @override
  Widget build(BuildContext context) => ToastColumn(
        toasts: _shown.reversed.take(6).toList().reversed.toList(),
        onTap: _open,
        chatTaps: widget.onOpenChat != null,
      );
}

class ToastColumn extends StatelessWidget {
  final List<ShellToast> toasts;
  /// Clicks on chat toasts and those with their own action
  /// ([ShellToast.clickable]); null (or any other toast): clicks pass
  /// through.
  final ValueChanged<ShellToast>? onTap;
  /// Chat toasts take clicks (off: only those with their own action).
  final bool chatTaps;
  const ToastColumn({super.key, required this.toasts, this.onTap, this.chatTaps = true});

  Widget _card(ShellToast t) {
    final card = ToastCard(toast: t);
    final tap = onTap;
    final clickable = t.onTap != null || (t.chat && chatTaps);
    final Widget body = !clickable || tap == null || t.leaving
        ? IgnorePointer(child: card)
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey(t.chat ? 'toast-open-chat-${t.id}' : 'toast-tap-${t.id}'),
              onTap: () => tap(t),
              child: card,
            ),
          );
    final who = t.who;
    if (who == null || t.leaving) return body;
    // The sender's picture is theirs: their card on it (the rest of a
    // toast still lets clicks through).
    return Stack(children: [
      body,
      Positioned(
        left: ToastCard.avatarInset,
        top: ToastCard.avatarInset,
        width: ToastCard.avatarSize,
        height: ToastCard.avatarSize,
        child: PersonHover(
          key: ValueKey('toast-person-${t.id}'),
          person: PersonRef.of(who),
          child: const SizedBox.expand(),
        ),
      ),
    ]);
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

  /// Where the sender's avatar sits in the card, and its size.
  static const avatarInset = 10.0;
  static const avatarSize = 38.0;

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
          padding: const EdgeInsets.fromLTRB(avatarInset, avatarInset, 16, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: who == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (who != null)
                LineAvatar(info: who, size: avatarSize)
              else if (toast.picture case final picture?)
                _Picture(bytes: picture)
              else if (toast.thumb.isNotEmpty)
                _Thumb(hash: toast.thumb)
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
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: toast.chat ? 15 : 14,
                        color: toast.chat || who == null ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (who != null && toast.thumb.isNotEmpty) ...[
                const SizedBox(width: 12),
                _Thumb(hash: toast.thumb),
              ],
              // A click edits it (a screenshot: crop, subtitles).
              if (toast.onTap != null) ...[
                const SizedBox(width: 10),
                Icon(Icons.crop_rounded, size: 18, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A toast's own picture (a screenshot), at most 68 x 52, its aspect
/// kept.
class _Picture extends StatelessWidget {
  final Uint8List bytes;
  const _Picture({required this.bytes});

  @override
  Widget build(BuildContext context) => ClipRRect(
        key: const ValueKey('toast-picture'),
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 68, maxHeight: 52, minWidth: 24, minHeight: 24),
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
        ),
      );
}

/// An Up next item's picture (16:9, from the queue's picture cache);
/// a blank until it is fetched.
class _Thumb extends StatelessWidget {
  final String hash;
  const _Thumb({required this.hash});

  @override
  Widget build(BuildContext context) {
    final thumbs = AppScope.of(context).coordinator.queue.thumbs;
    return ClipRRect(
      key: const ValueKey('toast-thumb'),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 68,
        height: 38,
        child: ListenableBuilder(
          listenable: thumbs,
          builder: (context, _) {
            final bytes = thumbs.bytesFor(hash);
            if (bytes == null) return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
            return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
          },
        ),
      ),
    );
  }
}
