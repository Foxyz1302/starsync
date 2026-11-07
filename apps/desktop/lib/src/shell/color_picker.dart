import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session/identity.dart' show colorFromWire, colorToWire;

/// `#rrggbb` (or `rrggbb`, `#rgb`) typed by someone as a colour; null
/// while it is not one.
Color? colorFromHex(String text) {
  var t = text.trim();
  if (t.startsWith('#')) t = t.substring(1);
  if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(t)) t = [for (final c in t.split('')) '$c$c'].join();
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(t) ? colorFromWire('#${t.toLowerCase()}') : null;
}

/// Any colour, compactly: hue across and saturation down in one area, a
/// brightness bar under it, and the hex code. Every change goes to
/// [onChanged] at once.
class ColorPicker extends StatefulWidget {
  final Color value;
  final ValueChanged<Color> onChanged;
  const ColorPicker({super.key, required this.value, required this.onChanged});

  static const areaHeight = 96.0;

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.value);
  late final _hex = TextEditingController(text: _wire(widget.value));
  final _hexFocus = FocusNode(debugLabel: 'colour hex');

  static String _wire(Color c) => colorToWire(c).substring(1);

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus) _hex.text = _wire(_hsv.toColor());
    });
  }

  @override
  void didUpdateWidget(ColorPicker old) {
    super.didUpdateWidget(old);
    // Picked elsewhere (a swatch): follow it, keeping the hue of a grey.
    if (widget.value.toARGB32() != _hsv.toColor().toARGB32()) {
      final next = HSVColor.fromColor(widget.value);
      _hsv = next.saturation == 0 || next.value == 0 ? next.withHue(_hsv.hue) : next;
      if (!_hexFocus.hasFocus) _hex.text = _wire(widget.value);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  void _set(HSVColor next) {
    setState(() => _hsv = next);
    final c = next.toColor();
    if (!_hexFocus.hasFocus) _hex.text = _wire(c);
    widget.onChanged(c);
  }

  void _area(Offset p, Size size) => _set(_hsv
      .withHue((p.dx / size.width).clamp(0.0, 1.0) * 359.999)
      .withSaturation(1 - (p.dy / size.height).clamp(0.0, 1.0)));

  void _value(Offset p, Size size) => _set(_hsv.withValue((p.dx / size.width).clamp(0.0, 1.0)));

  void _typed(String text) {
    final c = colorFromHex(text);
    if (c == null) return;
    final next = HSVColor.fromColor(c);
    setState(() => _hsv = next.saturation == 0 || next.value == 0 ? next.withHue(_hsv.hue) : next);
    widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget drag(Key key, double height, CustomPainter painter, void Function(Offset, Size) onAt) => LayoutBuilder(
          builder: (context, c) {
            final size = Size(c.maxWidth, height);
            return MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: GestureDetector(
                key: key,
                behavior: HitTestBehavior.opaque,
                onPanDown: (d) => onAt(d.localPosition, size),
                onPanUpdate: (d) => onAt(d.localPosition, size),
                child: CustomPaint(size: size, painter: painter),
              ),
            );
          },
        );
    return Column(
      key: const ValueKey('color-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        drag(const ValueKey('color-area'), ColorPicker.areaHeight, _AreaPainter(_hsv), _area),
        const SizedBox(height: 10),
        drag(const ValueKey('color-value'), 14, _ValuePainter(_hsv), _value),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _hsv.toColor(),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 104,
              child: TextField(
                key: const ValueKey('color-hex'),
                controller: _hex,
                focusNode: _hexFocus,
                maxLength: 7,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]'))],
                style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  prefixText: '#',
                  prefixStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  hintText: 'rrggbb',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: const OutlineInputBorder(),
                ),
                onChanged: _typed,
                onSubmitted: (_) => _hex.text = _wire(_hsv.toColor()),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Drag to pick, or type a code',
                  maxLines: 2, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Every hue across, full saturation at the top fading to white at the
/// bottom, at the picked brightness; a ring where the colour is.
class _AreaPainter extends CustomPainter {
  final HSVColor hsv;
  const _AreaPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(colors: [
          for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h % 360.0, 1, 1).toColor(),
        ]).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 1 - hsv.value));
    canvas.restore();
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white.withValues(alpha: 0.14));
    final at = Offset(hsv.hue / 360 * size.width, (1 - hsv.saturation) * size.height);
    _thumb(canvas, at, hsv.toColor());
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.hsv != hsv;
}

/// Black to the full-brightness colour; a ring at the picked brightness.
class _ValuePainter extends CustomPainter {
  final HSVColor hsv;
  const _ValuePainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2));
    canvas.drawRRect(
      r,
      Paint()..shader = LinearGradient(colors: [Colors.black, hsv.withValue(1).toColor()]).createShader(rect),
    );
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white.withValues(alpha: 0.14));
    final x = (hsv.value * size.width).clamp(size.height / 2, size.width - size.height / 2);
    _thumb(canvas, Offset(x, size.height / 2), hsv.toColor());
  }

  @override
  bool shouldRepaint(_ValuePainter old) => old.hsv != hsv;
}

void _thumb(Canvas canvas, Offset at, Color fill) {
  canvas.drawCircle(at, 8.5, Paint()..color = Colors.black.withValues(alpha: 0.45));
  canvas.drawCircle(at, 7.5, Paint()..color = Colors.white);
  canvas.drawCircle(at, 5.5, Paint()..color = fill);
}
