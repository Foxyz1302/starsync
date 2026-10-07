import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../jellyfin/track_prefs.dart' show MpvTrack;
import '../../playback/media_marks.dart';
import '../../screens/session/player_controls.dart' show TrackPick;
import 'controls.dart';
import 'style.dart';

/// One row of a uosc menu: [title], a dim [hint] on the right (a time, a
/// key), [active] = the current one (highlighted).
class UoscMenuItem<T> {
  final T value;
  final String title;
  final String? hint;
  final bool active;
  final bool enabled;
  const UoscMenuItem({
    required this.value,
    required this.title,
    this.hint,
    this.active = false,
    this.enabled = true,
  });
}

/// A flat dark menu over the controls, above the widget of [context] (the
/// button that opens it), with an optional [title] row. Resolves to the
/// picked value, or null when dismissed (click outside, Esc). Keeps the
/// controls up while open.
Future<T?> showUoscMenu<T>(
  BuildContext context, {
  String? title,
  required List<UoscMenuItem<T>> items,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  final box = context.findRenderObject() as RenderBox;
  final anchor = Rect.fromPoints(
    box.localToGlobal(Offset.zero, ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  Future<T?> open() => navigator.push<T>(_UoscMenuRoute<T>(anchor: anchor, title: title, items: items));
  final controls = UoscControls.maybeOf(context);
  return controls == null ? open() : controls.holdDuring(open);
}

class _UoscMenuRoute<T> extends PopupRoute<T> {
  final Rect anchor;
  final String? title;
  final List<UoscMenuItem<T>> items;
  _UoscMenuRoute({required this.anchor, required this.title, required this.items});

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close menu';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return LayoutBuilder(builder: (context, constraints) {
      const width = 360.0;
      final screen = constraints.biggest;
      final left = anchor.left.clamp(8.0, math.max(8.0, screen.width - width - 8));
      final maxHeight = math.max(120.0, anchor.top - 16);
      return Stack(
        children: [
          Positioned(
            left: left.toDouble(),
            bottom: screen.height - anchor.top + 6,
            width: math.min(width, screen.width - 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: UoscMenuPanel<T>(
                title: title,
                items: items,
                onPick: (v) => Navigator.of(context).pop(v),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// The menu's panel alone (tests pump it without a route).
class UoscMenuPanel<T> extends StatefulWidget {
  final String? title;
  final List<UoscMenuItem<T>> items;
  final ValueChanged<T> onPick;
  const UoscMenuPanel({super.key, this.title, required this.items, required this.onPick});

  static const rowHeight = 36.0;

  @override
  State<UoscMenuPanel<T>> createState() => _UoscMenuPanelState<T>();
}

class _UoscMenuPanelState<T> extends State<UoscMenuPanel<T>> {
  // Long lists open on the current row.
  late final _scroll = ScrollController(
      initialScrollOffset: math.max(0, widget.items.indexWhere((i) => i.active) - 3) * UoscMenuPanel.rowHeight);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    return Material(
      key: const ValueKey('uosc-menu'),
      color: UoscStyle.panel,
      borderRadius: BorderRadius.circular(UoscStyle.radius * 2),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Container(
              height: 34,
              alignment: Alignment.center,
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x22FFFFFF)))),
              child: Text(title,
                  style: const TextStyle(color: UoscStyle.dim, fontSize: UoscStyle.fontSize, fontWeight: FontWeight.w600)),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(4),
              controller: _scroll,
              itemCount: widget.items.length,
              itemExtent: UoscMenuPanel.rowHeight,
              itemBuilder: (context, i) => _Row<T>(item: widget.items[i], onPick: widget.onPick),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row<T> extends StatefulWidget {
  final UoscMenuItem<T> item;
  final ValueChanged<T> onPick;
  const _Row({super.key, required this.item, required this.onPick});

  @override
  State<_Row<T>> createState() => _RowState<T>();
}

class _RowState<T> extends State<_Row<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final color = item.active
        ? UoscStyle.fill
        : _hover && item.enabled
            ? UoscStyle.hover
            : Colors.transparent;
    final textColor = item.enabled ? UoscStyle.text : UoscStyle.dim.withValues(alpha: 0.4);
    return MouseRegion(
      cursor: item.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: ValueKey('uosc-menu-item-${item.title}'),
        behavior: HitTestBehavior.opaque,
        onTap: item.enabled ? () => widget.onPick(item.value) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(UoscStyle.radius)),
          child: Row(
            children: [
              Expanded(
                child: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: textColor,
                        fontSize: UoscStyle.fontSize,
                        fontWeight: item.active ? FontWeight.w600 : FontWeight.normal)),
              ),
              if (item.hint != null) ...[
                const SizedBox(width: 12),
                Text(item.hint!,
                    style: TextStyle(
                        color: item.active ? UoscStyle.text : UoscStyle.dim,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Chapters with their start times, the playing one active.
List<UoscMenuItem<MediaChapter>> chapterMenuItems(List<MediaChapter> chapters, int? current, Duration duration) {
  final withHours = duration >= const Duration(hours: 1);
  return [
    for (final c in chapters)
      UoscMenuItem(
        value: c,
        title: c.title.isEmpty ? 'Chapter ${c.index + 1}' : c.title,
        hint: formatUoscTime(c.start, withHours: withHours),
        active: c.index == current,
      ),
  ];
}

/// The audio or subtitle tracks ("Japanese · E-AC3 2.0 · title"), mpv's
/// selection active; subtitles start with Off.
List<UoscMenuItem<TrackPick>> trackMenuItems(JellyfinStreamType type, List<MpvTrack> tracks) {
  final audio = type == JellyfinStreamType.audio;
  final list = tracks.where((t) => t.type == type).toList();
  return [
    if (!audio)
      UoscMenuItem(
        value: (aid: null, sid: null, subtitlesOff: true),
        title: 'Off',
        active: !list.any((t) => t.selected),
      ),
    for (final t in list)
      UoscMenuItem(
        value: audio ? (aid: t.id, sid: null, subtitlesOff: false) : (aid: null, sid: t.id, subtitlesOff: false),
        title: t.label,
        hint: '#${t.id}',
        active: t.selected,
      ),
  ];
}
