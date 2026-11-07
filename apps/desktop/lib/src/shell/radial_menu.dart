import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../widgets/app_menu.dart' show AppMenuStyle;
import 'motion.dart';

// The player's radial menu (right button on the video; ARCHITECTURE
// "Desktop UI", "Space and the radial"): a dark disc around where the
// right button went down, four fixed places round it (the first straight
// up, the rest clockwise), a wedge under the slot the pointer points at, a
// dot in the centre following the pointer while the button is held, and
// the centre to cancel. No blur: the solid tint reads the same over any
// picture and costs nothing in fullscreen.

/// The radial's slot under [delta] (from the menu's centre) with [count]
/// slots, the first straight up and the rest clockwise; null inside the
/// [dead] radius (the centre cancels).
int? radialSlot(Offset delta, int count, {double dead = 36}) {
  if (delta.distance < dead || count <= 0) return null;
  // 0 = up, clockwise.
  var a = math.atan2(delta.dx, -delta.dy);
  if (a < 0) a += 2 * math.pi;
  final step = 2 * math.pi / count;
  return ((a + step / 2) ~/ step) % count;
}

/// The centre angle of [slot] (0 = up, clockwise, radians).
double radialAngle(int slot, int count) => slot * 2 * math.pi / count;

class RadialItem {
  final String id;
  final String label;
  final IconData icon;
  final bool enabled;

  /// Said under a disabled slot ("at the ending").
  final String? why;

  /// A shorter label for a slot too narrow for [label] ("Next").
  final String? short;

  /// No action in this slot: an empty, darker sector (the others keep
  /// their places).
  final bool blank;
  const RadialItem(this.id, this.label, this.icon, {this.enabled = true, this.why, this.short}) : blank = false;
  const RadialItem.blank()
    : id = '',
      label = '',
      icon = Icons.circle,
      enabled = false,
      why = null,
      short = null,
      blank = true;
}

/// The disc's size.
abstract final class RadialSize {
  static const outer = 124.0;
  static const inner = 34.0;

  /// Words keep this far off the centre ring, the rim and the dividers.
  static const pad = 7.0;
  static const icon = 22.0;
  static const iconGap = 3.0;

  /// The slot pointed at grows this much.
  static const hotScale = 1.08;

  static TextStyle label(bool hot) =>
      TextStyle(fontSize: 12, fontWeight: hot ? FontWeight.w700 : FontWeight.w500, height: 1.15);
  static const sub = TextStyle(fontSize: 9.5, height: 1.15);
}

class RadialMenuView extends StatefulWidget {
  final List<RadialItem> items;

  /// The slot pointed at, or null (the centre).
  final int? hot;

  /// The pointer from the centre while the button is held (the dot).
  final Offset? pointer;

  /// Drawn this many times its base size ([RadialSize]), about its centre
  /// (the layout box stays the base size); [pointer] is in base units.
  final double scale;
  const RadialMenuView({super.key, required this.items, this.hot, this.pointer, this.scale = 1});

  @override
  State<RadialMenuView> createState() => _RadialMenuViewState();
}

class _RadialMenuViewState extends State<RadialMenuView> with TickerProviderStateMixin {
  /// Opening: a quick scale and fade in, shorter than the shell's
  /// [easeTime] (a menu under the hand has to be there at once).
  late final AnimationController _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 150))
    ..forward();

  /// The wedge glides from the last slot to the new one.
  late final AnimationController _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 110));
  double _fromAngle = 0, _toAngle = 0;
  late final AnimationController _wedge = AnimationController(vsync: this, duration: const Duration(milliseconds: 90));

  @override
  void initState() {
    super.initState();
    final h = widget.hot;
    if (h != null) {
      _fromAngle = _toAngle = radialAngle(h, widget.items.length);
      _wedge.value = 1;
    }
  }

  @override
  void didUpdateWidget(RadialMenuView old) {
    super.didUpdateWidget(old);
    final h = widget.hot;
    if (h == old.hot && widget.items.length == old.items.length) return;
    if (h == null) {
      _wedge.reverse();
      return;
    }
    final target = radialAngle(h, widget.items.length);
    if (_wedge.value == 0) {
      // From the centre: appear in place.
      _fromAngle = _toAngle = target;
      _glide.value = 1;
    } else {
      _fromAngle = _angleNow();
      // The short way round.
      var t = target;
      while (t - _fromAngle > math.pi) {
        t -= 2 * math.pi;
      }
      while (_fromAngle - t > math.pi) {
        t += 2 * math.pi;
      }
      _toAngle = t;
      _glide.forward(from: 0);
    }
    _wedge.forward();
  }

  double _angleNow() => lerpDouble(_fromAngle, _toAngle, ease.transform(_glide.value))!;

  @override
  void dispose() {
    _open.dispose();
    _glide.dispose();
    _wedge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const d = RadialSize.outer * 2;
    final n = widget.items.length;
    final disc = ClipOval(
      child: SizedBox.square(
        dimension: d,
        child: CustomPaint(
          painter: _DiscPainter(
            count: n,
            wedge: _wedge,
            glide: _glide,
            angle: _angleNow,
            accent: scheme.primary,
            pointer: widget.pointer,
            blanks: [
              for (var i = 0; i < n; i++)
                if (widget.items[i].blank) i,
            ],
          ),
        ),
      ),
    );
    final items = [
      for (var i = 0; i < n; i++)
        if (!widget.items[i].blank) _slot(i, widget.items[i], i == widget.hot),
    ];
    final body = Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppMenuStyle.solid,
            border: Border.all(color: AppMenuStyle.border, width: 0.5),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8))],
          ),
          child: const SizedBox.square(dimension: d),
        ),
        disc,
        ...items,
        Positioned.fill(
          child: Center(
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: Colors.white.withValues(alpha: widget.hot == null ? 0.7 : 0.3),
            ),
          ),
        ),
      ],
    );
    return SizedBox.square(
      dimension: d,
      child: AnimatedBuilder(
        animation: Listenable.merge([_open, _glide, _wedge]),
        builder: (context, child) {
          final a = ease.transform(_open.value);
          return Opacity(
            opacity: a,
            child: Transform.scale(scale: widget.scale * (0.86 + 0.14 * a), child: child),
          );
        },
        child: RepaintBoundary(child: body),
      ),
    );
  }

  Widget _slot(int i, RadialItem item, bool hot) {
    final n = widget.items.length;
    final a = radialAngle(i, n);
    final fit = slotFit(item, n, a, DefaultTextStyle.of(context).style);
    final c =
        Offset(math.sin(a) * fit.radius, -math.cos(a) * fit.radius) + const Offset(RadialSize.outer, RadialSize.outer);
    final alpha = !item.enabled ? 0.35 : (hot ? 1.0 : 0.8);
    return Positioned(
      left: c.dx - fit.width / 2,
      top: c.dy - fit.height / 2,
      width: fit.width,
      height: fit.height,
      child: AnimatedScale(
        scale: hot && item.enabled ? RadialSize.hotScale : 1,
        duration: const Duration(milliseconds: 110),
        curve: ease,
        // Measured to fit; a font whose lines run a fraction taller than
        // measured spills evenly instead of overflowing.
        child: OverflowBox(
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                item.icon,
                size: RadialSize.icon,
                color: Colors.white.withValues(alpha: alpha),
              ),
              const SizedBox(height: RadialSize.iconGap),
              // Laid out to fit already, wrapping at the measured width (a
              // FittedBox alone lays its child out unbounded: no wrap); the
              // FittedBox only guards a font wider than measured.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: fit.width,
                  child: Text(
                    fit.label,
                    maxLines: fit.lines,
                    textAlign: TextAlign.center,
                    style: RadialSize.label(hot).copyWith(
                      color: Colors.white.withValues(alpha: alpha),
                      fontSize: RadialSize.label(hot).fontSize! * fit.scale,
                    ),
                  ),
                ),
              ),
              if (fit.sub)
                Text(
                  item.why!,
                  maxLines: 1,
                  style: RadialSize.sub.copyWith(color: Colors.white.withValues(alpha: 0.35)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How a slot's words are laid out to fit inside its slice.
class SlotFit {
  final String label;
  final int lines;

  /// The label's size against [RadialSize.label] (a narrow slot: 0.9).
  final double scale;

  /// The subline (why it is disabled) fits too.
  final bool sub;
  final double width, height;

  /// The radius of the box's centre.
  final double radius;
  const SlotFit(this.label, this.lines, this.sub, this.width, this.height, this.radius, {this.scale = 1});
}

/// The largest centred box of height 2 × [hh] around the middle of the
/// slice at [angle] (of [count]) that stays [RadialSize.pad] inside it
/// (off the centre ring, the rim and both dividers): its half width.
double slotHalfWidth(double angle, int count, double hh, {double mid = (RadialSize.outer + RadialSize.inner) / 2}) {
  final p = Offset(math.sin(angle) * mid, -math.cos(angle) * mid);
  final half = math.pi / count;
  const pad = RadialSize.pad;
  bool inside(Offset q) {
    final r = q.distance;
    if (r < RadialSize.inner + pad || r > RadialSize.outer - pad) return false;
    var d = math.atan2(q.dx, -q.dy) - angle;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    if (d.abs() >= half) return false;
    // Distance to the nearer divider.
    return r * math.sin(half - d.abs()) >= pad || half - d.abs() >= math.pi / 2;
  }

  bool fits(double hw) {
    // The box's edges, sampled.
    for (var k = 0; k <= 8; k++) {
      final t = -1 + k / 4;
      for (final q in [Offset(hw * t, -hh), Offset(hw * t, hh), Offset(-hw, hh * t), Offset(hw, hh * t)]) {
        if (!inside(p + q)) return false;
      }
    }
    return true;
  }

  var lo = 0.0, hi = RadialSize.outer;
  if (!fits(lo)) return 0;
  for (var k = 0; k < 18; k++) {
    final m = (lo + hi) / 2;
    if (fits(m)) {
      lo = m;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// The widest box of half height [hh] for the slot at [angle]: its half
/// width and the radius of its centre (slid along the slot's middle line;
/// a diagonal slot has more room further out).
(double, double) slotBox(double angle, int count, double hh) {
  var best = (0.0, (RadialSize.outer + RadialSize.inner) / 2);
  for (var r = RadialSize.inner + RadialSize.pad; r <= RadialSize.outer - RadialSize.pad; r += 1) {
    final w = slotHalfWidth(angle, count, hh, mid: r);
    if (w > best.$1 + 0.5) best = (w, r);
  }
  return best;
}

final _fitCache = <(String, String?, String?, bool, int, double, String?), SlotFit>{};

/// The roomiest layout of [item]'s words that fits its slice (at the hot
/// size, the box slid out along the slot's middle where that gives more
/// room): one line with the subline, two lines with it, then without it;
/// the same a little smaller, then the short label; last, one line
/// shrunk to the width. [base]: the text style in use
/// (its font).
SlotFit slotFit(RadialItem item, int count, double angle, TextStyle base) {
  final sub = !item.enabled && item.why != null;
  return _fitCache.putIfAbsent((item.label, item.short, item.why, sub, count, angle, base.fontFamily), () {
    double measure(String text, TextStyle style, double maxW, int lines) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: lines,
      )..layout(maxWidth: maxW);
      final over = tp.didExceedMaxLines || tp.width > maxW + 0.01;
      final w = over ? double.infinity : tp.width;
      tp.dispose();
      return w;
    }

    final full = base.merge(RadialSize.label(true));
    final subStyle = base.merge(RadialSize.sub);
    final subH = subStyle.fontSize! * subStyle.height!;
    // The full label, then a little smaller, then the short one.
    final tries = [(item.label, 1.0), (item.label, 0.9), if (item.short != null) (item.short!, 1.0)];
    for (final (label, scale) in tries) {
      final style = full.copyWith(fontSize: full.fontSize! * scale);
      final lineH = style.fontSize! * style.height!;
      for (final withSub in sub ? [true, false] : [false]) {
        for (final lines in [1, 2]) {
          final h = RadialSize.icon + RadialSize.iconGap + lineH * lines + (withSub ? subH : 0);
          // Room for the hot slot's growth.
          final hh = h * RadialSize.hotScale / 2;
          final (hw, r) = slotBox(angle, count, hh);
          final w = hw * 2 / RadialSize.hotScale;
          if (w < RadialSize.icon) continue;
          if (measure(label, style, w, lines).isInfinite) continue;
          if (withSub && measure(item.why!, subStyle, w, 1).isInfinite) continue;
          return SlotFit(label, lines, withSub, w, h, r, scale: scale);
        }
      }
    }
    final lineH = full.fontSize! * full.height!;
    final h = RadialSize.icon + RadialSize.iconGap + lineH;
    final (hw, r) = slotBox(angle, count, h * RadialSize.hotScale / 2);
    return SlotFit(item.short ?? item.label, 1, false, math.max(hw * 2 / RadialSize.hotScale, RadialSize.icon), h, r);
  });
}

class _DiscPainter extends CustomPainter {
  final int count;
  final Animation<double> wedge;
  final double Function() angle;
  final Color accent;
  final Offset? pointer;
  _DiscPainter({
    required this.count,
    required this.wedge,
    required Animation<double> glide,
    required this.angle,
    required this.accent,
    required this.pointer,
    this.blanks = const [],
  }) : super(repaint: Listenable.merge([wedge, glide]));

  /// Slots with no action: drawn darker.
  final List<int> blanks;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const ro = RadialSize.outer, ri = RadialSize.inner;
    final step = 2 * math.pi / count;
    // The wedge under the slot pointed at: exactly the slot's sector,
    // centre to rim (the disc's clip rounds it); the dividers go on top.
    final w = ease.transform(wedge.value);
    if (w > 0) {
      // Ours: 0 = up, clockwise; the canvas: 0 = right, clockwise.
      final start = angle() - step / 2 - math.pi / 2;
      final path = Path()
        ..addArc(Rect.fromCircle(center: c, radius: ro + 1), start, step)
        ..arcTo(Rect.fromCircle(center: c, radius: ri), start + step, -step, false)
        ..close();
      canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.42 * w));
    }
    for (final b in blanks) {
      final start = radialAngle(b, count) - step / 2 - math.pi / 2;
      canvas.drawPath(
        Path()
          ..addArc(Rect.fromCircle(center: c, radius: ro + 1), start, step)
          ..arcTo(Rect.fromCircle(center: c, radius: ri), start + step, -step, false)
          ..close(),
        Paint()..color = Colors.black.withValues(alpha: 0.32),
      );
    }
    // Slot dividers, on the sectors' edges.
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    for (var i = 0; i < count; i++) {
      final a = radialAngle(i, count) + step / 2;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c + dir * ri, c + dir * ro, line);
    }
    // The centre.
    canvas.drawCircle(c, ri, Paint()..color = Colors.black.withValues(alpha: 0.28));
    canvas.drawCircle(
      c,
      ri,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = Colors.white.withValues(alpha: 0.12),
    );
    // The pointer's direction, inside the centre (clear of the slices and
    // their words).
    final p = pointer;
    if (p != null && p.distance > 2) {
      final dir = p / p.distance;
      canvas.drawCircle(c + dir * (ri - 9), 3, Paint()..color = Colors.white.withValues(alpha: 0.85));
    }
  }

  @override
  bool shouldRepaint(_DiscPainter old) =>
      old.count != count || old.pointer != pointer || old.accent != accent || old.blanks.length != blanks.length;
}
