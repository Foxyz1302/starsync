import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../session/notifier.dart' show NoticeCategory, ToastItem;
import '../shell/avatar.dart' show AvatarInfo, colorForName;
import 'danmaku.dart';

// "Notifications: Danmaku" (Settings → Notifications & sounds): over the
// full player, chat and short notices fly across the picture instead of
// popping up as toasts. Problems, errors and the app's own notices stay
// toasts, and so does everything while the player is small or closed.

/// Whether [t] flies as a line (when danmaku is the style in use): chat,
/// joins / leaves / lost connection / back, "starting now", and Up next
/// news someone caused (added, changed the video). Nudges, problems, your
/// own state and the app's notices stay toasts.
bool fliesAsDanmaku(ToastItem t) => switch (t.category) {
      NoticeCategory.chat || NoticeCategory.people || NoticeCategory.start => true,
      NoticeCategory.upNext => t.actor != null && t.actor!.isNotEmpty,
      _ => false,
    };

/// [t] as a line: the sender (their avatar from [avatar], their colour)
/// before what they said or did; "starting now" without one. Null for
/// what does not fly ([fliesAsDanmaku]).
DanmakuItem? danmakuForToast(ToastItem t, {AvatarInfo Function(String name, String id)? avatar}) {
  if (!fliesAsDanmaku(t)) return null;
  final who = t.actor;
  if (who == null || who.isEmpty) {
    return DanmakuItem(kind: DanmakuKind.starting, text: '▶  ${t.text}');
  }
  final pic = avatar?.call(who, t.actorId) ?? AvatarInfo(name: who, color: colorForName(who));
  final color = pic.color;
  if (t.chat && t.text.startsWith('$who: ')) {
    return DanmakuItem(
        kind: DanmakuKind.chat,
        sender: who,
        senderColor: color,
        text: t.text.substring(who.length + 2),
        own: t.own,
        avatar: pic);
  }
  final rest = t.text.startsWith('$who ') ? t.text.substring(who.length + 1) : t.text;
  final kind = switch (t.category) {
    NoticeCategory.upNext => DanmakuKind.upNext,
    _ when rest.startsWith('left') || rest.startsWith('lost') => DanmakuKind.leave,
    _ => DanmakuKind.join,
  };
  return DanmakuItem(kind: kind, sender: who, senderColor: color, text: rest, avatar: pic);
}

/// The session's lines over the picture: fresh toasts that fly
/// ([fliesAsDanmaku], and not [skip]) go to [controller] while this is
/// mounted (the player mounts it only while danmaku is the style and the
/// full player is up); what was there before it mounted is old news.
class DanmakuNotices extends StatefulWidget {
  final ReadonlySignal<List<ToastItem>> toasts;
  final ReadonlySignal<DanmakuStyle> style;
  final DanmakuController controller;
  final AvatarInfo Function(String name, String id)? avatar;

  /// Toasts to leave out (none today; a hook for callers).
  final bool Function(ToastItem t)? skip;
  const DanmakuNotices({
    super.key,
    required this.toasts,
    required this.style,
    required this.controller,
    this.avatar,
    this.skip,
  });

  @override
  State<DanmakuNotices> createState() => _DanmakuNoticesState();
}

class _DanmakuNoticesState extends State<DanmakuNotices> {
  late Set<int> _seen = {for (final t in widget.toasts.peek()) t.id};
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    _stop = effect(() {
      final items = widget.toasts.value;
      untracked(() {
        for (final t in items) {
          if (_seen.contains(t.id) || (widget.skip?.call(t) ?? false)) continue;
          final line = danmakuForToast(t, avatar: widget.avatar);
          if (line != null) widget.controller.add(line);
        }
        _seen = {for (final t in items) t.id};
      });
    });
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SignalBuilder(
        builder: (context) => DanmakuLayer(
          controller: widget.controller,
          style: widget.style.value,
          accent: Theme.of(context).colorScheme.primary,
        ),
      );
}
