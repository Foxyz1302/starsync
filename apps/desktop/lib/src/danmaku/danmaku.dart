import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../shell/avatar.dart' show AvatarInfo, LineAvatar;
import '../widgets/contrast.dart' show readableOn;

// Danmaku (Bilibili / niconico style): short lines that fly right to left
// across the upper part of the picture. Each line takes a free lane (no
// two ever touch), at most [DanmakuStyle.maxOnScreen] fly at once and the
// rest wait their turn; every line crosses in the same time, so a long
// one moves faster. The clock is the layer's own: lines keep flying while
// the video is paused. The session's notifications use it when the user
// picks "Notifications as danmaku" (`danmaku_notices.dart`); the dev
// preview tries it out (DEVELOPMENT.md "Dev tools").

/// What a line is: a chat message or a short notice.
enum DanmakuKind { chat, join, leave, upNext, starting }

/// One line: [sender] (a coloured prefix, [senderColor]) and [text];
/// [own] lines (this member's) get a hairline frame. [avatar]: the
/// sender's picture (or initial) before it; the app's own notices have
/// none.
@immutable
class DanmakuItem {
  final DanmakuKind kind;
  final String? sender;
  final Color? senderColor;
  final String text;
  final bool own;
  final AvatarInfo? avatar;
  const DanmakuItem(
      {required this.kind, required this.text, this.sender, this.senderColor, this.own = false, this.avatar});
}

/// How lines look and move. Persisted as [toJson] (Settings →
/// Notifications & sounds); [DanmakuStyle.fromJson] clamps every value to
/// its range ([limits]), so a hand-edited or older box never breaks it.
@immutable
class DanmakuStyle {
  /// Seconds a line takes from the right edge until it has left on the
  /// left, whatever its length.
  final double crossSecs;

  /// Lines on screen at once; more wait.
  final int maxOnScreen;

  /// The band the lanes fill, as fractions of the height from the top:
  /// below where top signs sit, never down into the dialogue.
  final double bandTop;
  final double bandBottom;
  final double opacity;

  /// Text size relative to the picture's height ([fontSizeFor]).
  final double size;

  /// Font weight of the text, 400 (regular) to 900 (black); the sender's
  /// name is a step bolder.
  final int weight;

  /// Width of the dark outline round the white text, logical px.
  final double outline;
  final bool highlightOwn;

  /// The sender's avatar before the line.
  final bool avatars;

  const DanmakuStyle({
    this.crossSecs = 8,
    this.maxOnScreen = 12,
    this.bandTop = 0.10,
    this.bandBottom = 0.45,
    this.opacity = 0.92,
    this.size = 1,
    this.weight = 600,
    this.outline = 1.4,
    this.highlightOwn = true,
    this.avatars = true,
  });

  /// The range of each knob (the settings' sliders use them too).
  static const limits = (
    crossSecs: (4.0, 16.0),
    maxOnScreen: (1, 40),
    band: (0.0, 0.9),
    minBand: 0.05,
    opacity: (0.3, 1.0),
    size: (0.6, 1.8),
    weight: (400, 900),
    outline: (0.0, 4.0),
  );

  DanmakuStyle copyWith({
    double? crossSecs,
    int? maxOnScreen,
    double? bandTop,
    double? bandBottom,
    double? opacity,
    double? size,
    int? weight,
    double? outline,
    bool? highlightOwn,
    bool? avatars,
  }) =>
      DanmakuStyle(
        crossSecs: crossSecs ?? this.crossSecs,
        maxOnScreen: maxOnScreen ?? this.maxOnScreen,
        bandTop: bandTop ?? this.bandTop,
        bandBottom: bandBottom ?? this.bandBottom,
        opacity: opacity ?? this.opacity,
        size: size ?? this.size,
        weight: weight ?? this.weight,
        outline: outline ?? this.outline,
        highlightOwn: highlightOwn ?? this.highlightOwn,
        avatars: avatars ?? this.avatars,
      );

  Map<String, Object> toJson() => {
        'crossSecs': crossSecs,
        'maxOnScreen': maxOnScreen,
        'bandTop': bandTop,
        'bandBottom': bandBottom,
        'opacity': opacity,
        'size': size,
        'weight': weight,
        'outline': outline,
        'highlightOwn': highlightOwn,
        'avatars': avatars,
      };

  /// [json] as stored ([toJson]); missing or wrong values take the
  /// default, out-of-range ones the nearest end of their range.
  factory DanmakuStyle.fromJson(Map<Object?, Object?> json) {
    const d = DanmakuStyle();
    const l = limits;
    double num_(String k, double def, (double, double) r) {
      final v = json[k];
      return v is num && v.isFinite ? v.toDouble().clamp(r.$1, r.$2) : def;
    }

    int int_(String k, int def, (int, int) r) {
      final v = json[k];
      return v is num && v.isFinite ? v.round().clamp(r.$1, r.$2) : def;
    }

    bool bool_(String k, bool def) {
      final v = json[k];
      return v is bool ? v : def;
    }

    var top = num_('bandTop', d.bandTop, l.band);
    var bottom = num_('bandBottom', d.bandBottom, l.band);
    if (bottom - top < l.minBand) (top, bottom) = (d.bandTop, d.bandBottom);
    return DanmakuStyle(
      crossSecs: num_('crossSecs', d.crossSecs, l.crossSecs),
      maxOnScreen: int_('maxOnScreen', d.maxOnScreen, l.maxOnScreen),
      bandTop: top,
      bandBottom: bottom,
      opacity: num_('opacity', d.opacity, l.opacity),
      size: num_('size', d.size, l.size),
      weight: (int_('weight', d.weight, l.weight) / 100).round() * 100,
      outline: num_('outline', d.outline, l.outline),
      highlightOwn: bool_('highlightOwn', d.highlightOwn),
      avatars: bool_('avatars', d.avatars),
    );
  }

  /// [weight] as a [FontWeight] (400..900 in steps of 100).
  FontWeight get fontWeight => FontWeight.values[((weight.clamp(100, 900) / 100).round() - 1)];

  /// The sender's name: a step bolder than the text.
  FontWeight get nameWeight =>
      FontWeight.values[math.min(FontWeight.values.length - 1, (weight.clamp(100, 900) / 100).round())];

  /// The text size in a picture [height] px tall: 4.2 % of it (about 30 px
  /// on a 720 px player), 13 to 44 px, times [size].
  double fontSizeFor(double height) => (height * 0.042).clamp(13.0, 44.0) * size;

  /// A lane: the line's height plus a little air.
  double laneHeightFor(double height) => fontSizeFor(height) * 1.5;

  /// Lanes in the band of a picture [height] px tall (at least one).
  int lanesFor(double height) {
    final band = (bandBottom - bandTop).clamp(0.0, 1.0) * height;
    return math.max(1, (band / laneHeightFor(height)).floor());
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuStyle &&
      other.crossSecs == crossSecs &&
      other.maxOnScreen == maxOnScreen &&
      other.bandTop == bandTop &&
      other.bandBottom == bandBottom &&
      other.opacity == opacity &&
      other.size == size &&
      other.weight == weight &&
      other.outline == outline &&
      other.highlightOwn == highlightOwn &&
      other.avatars == avatars;

  @override
  int get hashCode =>
      Object.hash(crossSecs, maxOnScreen, bandTop, bandBottom, opacity, size, weight, outline, highlightOwn, avatars);
}

/// One line in flight in [lane], from [start] (seconds on the layer's
/// clock), [width] px wide, crossing in [crossSecs].
class DanmakuFlight<T> {
  final T item;
  final int lane;
  final double start;
  final double width;
  final double crossSecs;
  DanmakuFlight({required this.item, required this.lane, required this.start, required this.width, required this.crossSecs});

  /// Its left edge at [t] in a picture [w] px wide: [w] at the start,
  /// -[width] at the end.
  double x(double t, double w) => w - (w + width) * ((t - start) / crossSecs);
  double end() => start + crossSecs;
  bool doneAt(double t) => t >= end();
}

/// Lane assignment, pure (no widgets, a clock passed in): lines queue in
/// order of arrival; [tick] lets the waiting ones in while a lane is free
/// and fewer than the cap fly. A lane is free for a new line when the last
/// line in it has fully entered with [gap] behind it and the new one, at
/// its own speed, cannot catch up with it before it has left.
class DanmakuLanes<T> {
  /// Space kept between two lines in a lane, px.
  final double gap;

  /// A line waiting longer than this is dropped (a burst on a crowded
  /// picture would otherwise fly long after it was said).
  final double maxWaitSecs;

  /// Lines kept waiting at most; older ones go first when it is full.
  final int maxWaiting;

  DanmakuLanes({this.gap = 24, this.maxWaitSecs = 15, this.maxWaiting = 60});

  final List<DanmakuFlight<T>> flights = [];
  final Queue<(T, double)> _waiting = Queue();
  int dropped = 0;

  int get waiting => _waiting.length;

  /// Everything flying and waiting goes; returns it.
  List<T> clear() {
    final all = [for (final f in flights) f.item, for (final w in _waiting) w.$1];
    flights.clear();
    _waiting.clear();
    return all;
  }

  /// [item] arrived at [t]; it flies on the next [tick] that has room.
  void add(T item, double t) {
    _waiting.add((item, t));
    while (_waiting.length > maxWaiting) {
      _waiting.removeFirst();
      dropped++;
    }
  }

  /// Advances to [t] in a picture [w] px wide with [lanes] lanes: drops
  /// what has left and what waited too long, then places waiting lines in
  /// order (the topmost free lane each) until the cap or no lane is free.
  /// [measure] gives a line's width. Returns the lines placed.
  List<DanmakuFlight<T>> tick(double t,
      {required double w, required int lanes, required int cap, required double crossSecs, required double Function(T) measure}) {
    flights.removeWhere((f) => f.doneAt(t));
    while (_waiting.isNotEmpty && t - _waiting.first.$2 > maxWaitSecs) {
      _waiting.removeFirst();
      dropped++;
    }
    final placed = <DanmakuFlight<T>>[];
    while (_waiting.isNotEmpty && flights.length < cap) {
      final item = _waiting.first.$1;
      final width = measure(item);
      final lane = freeLane(t, w: w, lanes: lanes, width: width, crossSecs: crossSecs);
      if (lane == null) break;
      _waiting.removeFirst();
      final f = DanmakuFlight(item: item, lane: lane, start: t, width: width, crossSecs: crossSecs);
      flights.add(f);
      placed.add(f);
    }
    return placed;
  }

  /// The topmost lane a line [width] px wide can start in at [t], or null.
  int? freeLane(double t, {required double w, required int lanes, required double width, required double crossSecs}) {
    final last = <int, DanmakuFlight<T>>{};
    for (final f in flights) {
      final l = last[f.lane];
      if (l == null || f.start > l.start) last[f.lane] = f;
    }
    for (var lane = 0; lane < lanes; lane++) {
      final prev = last[lane];
      if (prev == null || fits(prev, t, w: w, width: width, crossSecs: crossSecs, gap: gap)) return lane;
    }
    return null;
  }

  /// A new line ([width], [crossSecs]) may follow [prev] in its lane at [t].
  /// Both move linearly, so checking now and the moment [prev] has left is
  /// enough.
  static bool fits(DanmakuFlight<Object?> prev, double t,
      {required double w, required double width, required double crossSecs, required double gap}) {
    // Fully in, with the gap behind it.
    if (prev.x(t, w) + prev.width + gap > w) return false;
    final leaves = prev.end();
    if (leaves <= t) return true;
    // Where the new line's head is when prev's tail reaches the left edge.
    final head = w - (w + width) * ((leaves - t) / crossSecs);
    return head >= gap;
  }
}

/// Feeds a [DanmakuLayer]; [onScreen] / [waiting] follow what the layer
/// does with the lines (for a status readout).
class DanmakuController extends ChangeNotifier {
  final _inbox = <DanmakuItem>[];
  final onScreen = ValueNotifier(0);
  final waiting = ValueNotifier(0);
  final dropped = ValueNotifier(0);

  void add(DanmakuItem item) {
    _inbox.add(item);
    notifyListeners();
  }

  /// Everything in flight and waiting goes.
  void clear() {
    _clear = true;
    _inbox.clear();
    notifyListeners();
  }

  bool _clear = false;

  List<DanmakuItem> _take() {
    final items = List.of(_inbox);
    _inbox.clear();
    return items;
  }

  /// The layer showing the lines, while there is one.
  _DanmakuLayerState? _layer;

  /// The flying line whose sender (avatar and name) is at [global] now,
  /// with that part's rect on screen; null over anything else or a line
  /// with no sender.
  ({DanmakuItem item, Rect rect})? senderAt(Offset global) => _layer?._senderAt(global);

  @override
  void dispose() {
    onScreen.dispose();
    waiting.dispose();
    dropped.dispose();
    super.dispose();
  }
}

/// The lines over a picture: fills its box, lets every click through.
/// Each line is a widget (avatar, outlined text, own frame) moved by a
/// [Flow] on every frame: only paint runs per frame, a build only when a
/// line comes or goes.
class DanmakuLayer extends StatefulWidget {
  final DanmakuController controller;
  final DanmakuStyle style;

  /// The accent of [DanmakuItem.own] lines' frame and of "starting now".
  final Color accent;
  const DanmakuLayer({super.key, required this.controller, this.style = const DanmakuStyle(), required this.accent});

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

/// A line measured once (its width decides its speed and its lane) and
/// its widget, built once.
class _Line {
  final DanmakuItem item;
  final double width;
  final double height;
  final Widget widget;
  /// From the line's left edge: where its sender (avatar and name) ends;
  /// 0 when it names nobody.
  final double senderWidth;
  _Line(this.item, this.width, this.height, this.widget, {this.senderWidth = 0});
}

class _DanmakuLayerState extends State<DanmakuLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _lanes = DanmakuLanes<_Line>();
  final _repaint = ValueNotifier(0);
  // The layer's clock: [_base] from earlier runs of the ticker, which
  // only runs while lines fly or wait (an idle layer asks for no frames).
  Duration _base = Duration.zero;
  Duration _elapsed = Duration.zero;
  Size _size = Size.zero;
  var _pending = <DanmakuItem>[];
  var _shown = <DanmakuFlight<_Line>>[];

  double get _t => (_base + _elapsed).inMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onAdd);
    widget.controller._layer = this;
    _onAdd();
  }

  @override
  void didUpdateWidget(DanmakuLayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onAdd);
      if (old.controller._layer == this) old.controller._layer = null;
      widget.controller.addListener(_onAdd);
      widget.controller._layer = this;
    }
  }

  /// See [DanmakuController.senderAt]: where each line is at this
  /// moment, as the flow paints it.
  ({DanmakuItem item, Rect rect})? _senderAt(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final p = box.globalToLocal(global);
    final s = widget.style;
    final size = box.size;
    final top = s.bandTop * size.height;
    final lane = s.laneHeightFor(size.height);
    for (final f in _shown) {
      final l = f.item;
      if (l.senderWidth <= 0 || l.item.avatar == null) continue;
      final x = f.x(_t, size.width);
      final y = top + f.lane * lane + (lane - l.height) / 2;
      final r = Rect.fromLTWH(x, y, l.senderWidth, l.height);
      if (r.contains(p)) return (item: l.item, rect: box.localToGlobal(r.topLeft) & r.size);
    }
    return null;
  }

  @override
  void dispose() {
    if (widget.controller._layer == this) widget.controller._layer = null;
    widget.controller.removeListener(_onAdd);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onAdd() {
    final c = widget.controller;
    if (c._clear) {
      c._clear = false;
      _lanes.clear();
      _pending = [];
    }
    _pending.addAll(c._take());
    if (!_ticker.isActive) _ticker.start();
  }

  _Line _build(DanmakuItem item) {
    final s = widget.style;
    final size = s.fontSizeFor(_size.height);
    final base = TextStyle(
      fontSize: size,
      height: 1.2,
      fontWeight: s.fontWeight,
      color: Colors.white,
      letterSpacing: 0.2,
      shadows: const [],
    );
    InlineSpan span({Paint? stroke}) {
      final name = item.sender;
      final accent = item.kind == DanmakuKind.starting && stroke == null ? widget.accent : null;
      return TextSpan(style: stroke == null ? base : base.copyWith(foreground: stroke, color: null), children: [
        if (name != null)
          TextSpan(
            text: item.kind == DanmakuKind.chat ? '$name  ' : '$name ',
            style: TextStyle(
              fontWeight: s.nameWeight,
              // Too dark a colour is lifted to read over its dark outline.
              color: stroke == null ? readableOn(item.senderColor ?? Colors.white, Colors.black, min: 3) : null,
            ),
          ),
        TextSpan(text: item.text, style: accent == null ? null : TextStyle(color: accent)),
      ]);
    }

    final measure = TextPainter(text: span(), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    final textW = measure.width, textH = measure.height;
    measure.dispose();
    final avatar = s.avatars ? item.avatar : null;
    final avatarSize = size * 1.15;
    final avatarGap = size * 0.3;
    final frame = item.own && s.highlightOwn;
    final padX = frame ? size * 0.4 : 0.0;
    final width = textW + padX * 2 + (avatar == null ? 0 : avatarSize + avatarGap);
    Widget text = Text.rich(span(), maxLines: 1, softWrap: false);
    if (s.outline > 0) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.outline * 2
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xE6000000);
      text = Stack(children: [Text.rich(span(stroke: stroke), maxLines: 1, softWrap: false), text]);
    }
    Widget line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (avatar != null) ...[
          LineAvatar(info: avatar, size: avatarSize, marks: false),
          SizedBox(width: avatarGap),
        ],
        text,
      ],
    );
    if (frame) {
      line = DecoratedBox(
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: widget.accent.withValues(alpha: 0.85), width: 1.2),
        ),
        child: Padding(padding: EdgeInsets.symmetric(horizontal: padX), child: line),
      );
    }
    final height = math.max(textH, avatar == null ? 0.0 : avatarSize);
    // The sender's part (a click there opens their card).
    var senderWidth = 0.0;
    final name = item.sender;
    if (name != null && item.avatar != null) {
      final m = TextPainter(
          text: TextSpan(style: base, children: [TextSpan(text: name, style: TextStyle(fontWeight: s.nameWeight))]),
          textDirection: TextDirection.ltr,
          maxLines: 1)
        ..layout();
      senderWidth = padX + (avatar == null ? 0 : avatarSize + avatarGap) + m.width;
      m.dispose();
    }
    return _Line(item, width, height, SizedBox(width: width, height: height, child: Center(child: line)),
        senderWidth: senderWidth);
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (_size.isEmpty) return;
    final t = _t;
    for (final item in _pending) {
      _lanes.add(_build(item), t);
    }
    _pending = [];
    final s = widget.style;
    _lanes.tick(t,
        w: _size.width,
        lanes: s.lanesFor(_size.height),
        cap: s.maxOnScreen,
        crossSecs: s.crossSecs,
        measure: (l) => l.width);
    final c = widget.controller;
    c.onScreen.value = _lanes.flights.length;
    c.waiting.value = _lanes.waiting;
    c.dropped.value = _lanes.dropped;
    final now = List.of(_lanes.flights);
    if (now.length != _shown.length || !_sameFlights(now, _shown)) {
      setState(() => _shown = now);
    } else if (now.isNotEmpty) {
      _repaint.value++;
    }
    if (now.isEmpty && _lanes.waiting == 0 && _pending.isEmpty) {
      _base += _elapsed;
      _elapsed = Duration.zero;
      _ticker.stop();
    }
  }

  static bool _sameFlights(List<DanmakuFlight<_Line>> a, List<DanmakuFlight<_Line>> b) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        _size = box.biggest;
        return Opacity(
          opacity: widget.style.opacity.clamp(0.0, 1.0),
          child: Flow(
            delegate: _DanmakuFlow(this, _repaint),
            children: [for (final f in _shown) KeyedSubtree(key: ObjectKey(f), child: f.item.widget)],
          ),
        );
      }),
    );
  }
}

class _DanmakuFlow extends FlowDelegate {
  final _DanmakuLayerState state;
  _DanmakuFlow(this.state, Listenable repaint) : super(repaint: repaint);

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) => const BoxConstraints();

  @override
  void paintChildren(FlowPaintingContext context) {
    final s = state.widget.style;
    final size = context.size;
    final t = state._t;
    final top = s.bandTop * size.height;
    final lane = s.laneHeightFor(size.height);
    final flights = state._shown;
    for (var i = 0; i < flights.length && i < context.childCount; i++) {
      final f = flights[i];
      final x = f.x(t, size.width);
      final y = top + f.lane * lane + (lane - f.item.height) / 2;
      context.paintChild(i, transform: Matrix4.translationValues(x, y, 0));
    }
  }

  @override
  bool shouldRepaint(_DanmakuFlow old) => true;
}
