import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../schedule_model.dart';

// One day of the Schedule board and its airing cards: cover poster on the
// left (air time on it, download progress or this user's watch progress
// under it, a check once watched), title, episode and status on the
// right, one full-width action below. Compact mode is a slim row.

/// What a card's action does, decided by the page.
enum CardAction {
  none,
  putUp,

  /// Available, nobody else watching (offline or solo): plays it here.
  play,
  request,
  requestSeries,
  requested,
}

String _two(int n) => n.toString().padLeft(2, '0');

String clockText(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

String countdownText(DateTime at, DateTime now) {
  final d = at.difference(now);
  if (d.isNegative) return 'aired';
  if (d.inDays > 0) return 'in ${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return 'in ${d.inHours}h ${d.inMinutes % 60}m';
  return 'in ${d.inMinutes}m';
}

/// Aired, tracked, no release yet: AnimeFlow downloads it by itself.
bool _waiting(ScheduleEntry e, DateTime now) =>
    e.status == ScheduleStatus.missing ||
    (e.status == ScheduleStatus.upcoming && e.tracked && !e.airing.airingAt.isAfter(now));

const waitingHint = 'Aired in Japan; downloads automatically when a release appears';

/// Status line: text, colour, icon.
(String, Color, IconData) statusBadge(ScheduleEntry e, DateTime now) => _waiting(e, now)
    ? ('waiting for release', Colors.amber.shade200, Icons.hourglass_top)
    : switch (e.status) {
        ScheduleStatus.available => ('on Jellyfin', Colors.greenAccent, Icons.check_circle),
        ScheduleStatus.downloading => (
          e.progress == null ? 'downloading' : 'downloading ${(e.progress! * 100).round()}%',
          Colors.lightBlueAccent,
          Icons.downloading,
        ),
        ScheduleStatus.upcoming => (countdownText(e.airing.airingAt, now), Colors.amber, Icons.schedule),
        ScheduleStatus.missing => ('waiting for release', Colors.amber.shade200, Icons.hourglass_top),
        ScheduleStatus.failed => (
          'failed${e.reason == null ? '' : ' · ${e.reason}'}',
          Colors.redAccent,
          Icons.error_outline,
        ),
        ScheduleStatus.unmonitored => ('not monitored', Colors.grey, Icons.visibility_off_outlined),
        ScheduleStatus.notTracked => ('not in AnimeFlow', Colors.grey, Icons.public),
        ScheduleStatus.inLibrary => ('on Jellyfin', Colors.greenAccent, Icons.video_library_outlined),
        ScheduleStatus.notOnJellyfin => ('aired · not on Jellyfin yet', Colors.grey, Icons.hourglass_empty),
        ScheduleStatus.aired => ('aired', Colors.grey, Icons.done),
      };

/// What the status line means, when its text alone does not say.
String? statusHint(ScheduleEntry e, DateTime now) => _waiting(e, now) ? waitingHint : null;

class DayColumn extends StatelessWidget {
  final DateTime day;
  final bool today, past;
  final List<Widget> cards;
  final bool compact;
  const DayColumn({
    super.key,
    required this.day,
    required this.today,
    required this.past,
    required this.cards,
    required this.compact,
  });

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: today ? scheme.primary.withValues(alpha: 0.06) : scheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: today ? Border.all(color: scheme.primary.withValues(alpha: 0.5)) : null,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Text(
                  today ? 'Today' : _wd[day.weekday - 1],
                  style: TextStyle(fontWeight: FontWeight.w700, color: today ? scheme.primary : null),
                ),
                const SizedBox(width: 6),
                Text('${day.day}.${day.month}.', style: TextStyle(color: scheme.onSurfaceVariant)),
                const Spacer(),
                if (cards.isNotEmpty)
                  Text('${cards.length}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: past ? 0.85 : 1,
              child: cards.isEmpty
                  ? Center(
                      child: Text('—', style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  // The board's mouse drag is sideways only: a column scrolls by
                  // wheel (or touch), never by dragging the mouse.
                  : ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(dragDevices: {...PointerDeviceKind.values}..remove(PointerDeviceKind.mouse)),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                        itemCount: cards.length,
                        separatorBuilder: (_, _) => SizedBox(height: compact ? 6 : 10),
                        itemBuilder: (context, i) => cards[i],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class AiringCard extends StatelessWidget {
  final ScheduleEntry entry;
  final DateTime now;
  final bool compact;
  final CardAction action;

  /// Why [action] is disabled (no request scope, not on Jellyfin, ...);
  /// null = enabled.
  final String? disabledHint;

  /// A call for this card is in flight.
  final bool busy;
  final VoidCallback onAction;

  /// Right-click ([context]: the card): the page's menu; null: none.
  final void Function(BuildContext context)? onMenu;

  const AiringCard({
    super.key,
    required this.entry,
    required this.now,
    required this.compact,
    required this.action,
    required this.onAction,
    this.disabledHint,
    this.busy = false,
    this.onMenu,
  });

  String get _id => '${entry.airing.anilistId}-${entry.airing.episode}';

  Widget _image(String? url, Widget fallback) =>
      url == null ? fallback : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);

  static Widget _hinted(String? hint, Widget child) => hint == null ? child : Tooltip(message: hint, child: child);

  bool get _played => entry.watch?.played ?? false;

  /// A watched episode's cover is a little dimmer.
  Widget _dimmed(Widget cover) => _played ? Opacity(opacity: 0.6, child: cover) : cover;

  /// This user's state of the episode on Jellyfin: the library cards'
  /// green check once watched, else a thin bar to the resume point.
  List<Widget> _watchMarks({bool small = false}) {
    final w = entry.watch;
    if (w == null) return const [];
    if (w.played) {
      final size = small ? 16.0 : 22.0;
      return [
        Positioned(
          top: small ? 2 : 4,
          right: small ? 2 : 4,
          child: Tooltip(
            message: 'Watched',
            child: Container(
              key: ValueKey('watched-$_id'),
              constraints: BoxConstraints(minWidth: size, minHeight: size),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xCC1B5E20), borderRadius: BorderRadius.circular(size / 2)),
              child: Icon(Icons.check, size: small ? 11 : 14, color: Colors.white),
            ),
          ),
        ),
      ];
    }
    if (w.progress <= 0) return const [];
    return [
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Tooltip(
          message: '${(w.progress * 100).round()}% watched',
          child: LinearProgressIndicator(
            key: ValueKey('watch-progress-$_id'),
            value: w.progress,
            minHeight: small ? 2 : 3,
            backgroundColor: Colors.black54,
          ),
        ),
      ),
    ];
  }

  Widget? _button(BuildContext context) {
    final enabled = disabledHint == null && !busy;
    final spinner = const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    Widget? b = switch (action) {
      CardAction.none => null,
      CardAction.putUp || CardAction.play => FilledButton.tonalIcon(
        onPressed: enabled ? onAction : null,
        icon: busy ? spinner : const Icon(Icons.play_arrow, size: 18),
        label: Text(action == CardAction.play ? 'Play' : 'Put it up'),
      ),
      CardAction.request || CardAction.requestSeries => OutlinedButton.icon(
        onPressed: enabled ? onAction : null,
        icon: busy ? spinner : const Icon(Icons.download, size: 18),
        label: Text(action == CardAction.request ? 'Request' : 'Request series'),
      ),
      CardAction.requested => const OutlinedButton(onPressed: null, child: Text('Requested')),
    };
    if (b == null) return null;
    b = KeyedSubtree(key: ValueKey('action-$_id'), child: b);
    return disabledHint == null ? b : Tooltip(message: disabledHint!, child: b);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = entry.airing;
    final (label, color, icon) = statusBadge(entry, now);
    final hint = statusHint(entry, now);
    final time = clockText(a.airingAt);
    final tintColor = a.color ?? Colors.blueGrey;
    final tint = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tintColor.withValues(alpha: 0.85), tintColor.withValues(alpha: 0.35)],
        ),
      ),
    );
    final tap = (action == CardAction.putUp || action == CardAction.play) && disabledHint == null && !busy
        ? onAction
        : null;
    final onMenu = this.onMenu;
    final menu = onMenu == null || busy ? null : () => onMenu(context);
    if (compact) {
      final requestable = action == CardAction.request || action == CardAction.requestSeries;
      return Material(
        key: ValueKey('card-$_id'),
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: tap,
          onSecondaryTap: menu,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 34,
                    height: 48,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [_dimmed(_image(a.cover, tint)), ..._watchMarks(small: true)],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      Text('$time · E${a.episode}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
                    ],
                  ),
                ),
                if (requestable)
                  Tooltip(
                    message: disabledHint ?? (action == CardAction.request ? 'Request' : 'Request series'),
                    child: IconButton(
                      key: ValueKey('action-$_id'),
                      onPressed: disabledHint == null && !busy ? onAction : null,
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      icon: Icon(Icons.download, color: color),
                    ),
                  )
                else
                  Tooltip(
                    message: hint == null ? label : '$label: $hint',
                    child: Icon(icon, size: 16, color: color),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final button = _button(context);
    // The cover poster leads: it is what people recognise at a glance.
    return Material(
      key: ValueKey('card-$_id'),
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tap,
        onSecondaryTap: menu,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 84,
                      height: 120,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _dimmed(_image(a.cover, tint)),
                          Positioned(
                            left: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                time,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                            ),
                          ),
                          ..._watchMarks(),
                          if (entry.status == ScheduleStatus.downloading)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: entry.progress,
                                minHeight: 3,
                                color: Colors.lightBlueAccent,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 120,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.25),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Episode ${a.episode}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                          ),
                          const Spacer(),
                          _hinted(
                            hint,
                            Row(
                              children: [
                                Icon(icon, size: 14, color: color),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: color, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (button != null) ...[const SizedBox(height: 8), SizedBox(width: double.infinity, child: button)],
            ],
          ),
        ),
      ),
    );
  }
}
