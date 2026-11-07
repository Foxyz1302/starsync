import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import '../app/app_graph.dart';
import '../widgets/text_focus.dart' show KeyboardClaim;
import 'avatar.dart';

/// The file types the picker takes.
const pictureExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];

/// [path] is a picture the picker takes, by its extension.
bool isPicturePath(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && pictureExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// Ctrl+V (Cmd+V on macOS) or Shift+Insert: a paste.
bool isPasteKey(KeyEvent event, {required bool control, required bool meta, required bool shift}) {
  if (event is! KeyDownEvent) return false;
  final k = event.logicalKey;
  if (k == LogicalKeyboardKey.keyV) return Platform.isMacOS ? meta : control;
  return k == LogicalKeyboardKey.insert && shift;
}

/// Your picture: the app's own picker, open at once. A picture comes from
/// the clipboard (Ctrl+V or Paste), a drop, or the system's file chooser
/// (Browse…, only when clicked); then drag to move, scroll or slide to
/// zoom, with live previews at the sizes it is shown, all in the avatar
/// shape (Settings → Party → More). "Use this" renders a 256 px PNG of the
/// whole square (the shape is drawn where it shows).
class CropPicker extends StatefulWidget {
  final Future<void> Function(Uint8List png) onUse;
  const CropPicker({super.key, required this.onUse});

  @override
  State<CropPicker> createState() => _CropPickerState();
}

class _CropPickerState extends State<CropPicker> {
  static const _view = 300.0, _out = 256;
  final _focus = FocusNode(debugLabel: 'picture picker');
  ui.Image? _img;
  double _zoom = 1; // 1 = the image just covers the square
  Offset _pan = Offset.zero; // in viewport pixels
  String? _error;
  bool _busy = false;

  /// The system's file chooser is open (it can take a moment to show).
  bool _browsing = false;

  /// A drag with files is over the picker.
  bool _dropping = false;

  @override
  void dispose() {
    _focus.dispose();
    _img?.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    if (_browsing) return;
    setState(() => _browsing = true);
    final List<String> files;
    try {
      files = await AppScope.of(context).ports.folders
          .pickFiles(dialogTitle: 'Pick a picture', extensions: pictureExtensions);
    } catch (e) {
      if (mounted) setState(() => _error = "The file chooser didn't open. Try again, or paste or drop a picture");
      return;
    } finally {
      if (mounted) setState(() => _browsing = false);
    }
    final path = files.firstOrNull;
    if (path != null) await _loadFile(path);
  }

  Future<void> _paste() async {
    final bytes = await AppScope.of(context).ports.shell.readImage();
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _error = 'No picture on the clipboard. Copy one first');
      return;
    }
    await _load(bytes);
  }

  void _drop(List<String> paths) {
    setState(() => _dropping = false);
    final path = paths.where(isPicturePath).firstOrNull;
    if (path == null) {
      setState(() => _error = 'That is not a picture (PNG, JPG, WebP, GIF or BMP)');
      return;
    }
    _loadFile(path);
  }

  Future<void> _loadFile(String path) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't read that file");
      return;
    }
    await _load(bytes);
  }

  Future<void> _load(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      _img?.dispose();
      setState(() {
        _img = frame.image;
        _zoom = 1;
        _pan = Offset.zero;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't read that picture");
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    if (isPasteKey(event, control: keys.isControlPressed, meta: keys.isMetaPressed, shift: keys.isShiftPressed)) {
      _paste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  double get _scale {
    final img = _img!;
    return math.max(_view / img.width, _view / img.height) * _zoom;
  }

  /// Keeps the square covered: the image edge never shows inside it.
  Offset _clamp(Offset p) {
    final img = _img!;
    final mx = (img.width * _scale - _view) / 2, my = (img.height * _scale - _view) / 2;
    return Offset(p.dx.clamp(-mx, mx), p.dy.clamp(-my, my));
  }

  void _setZoom(double z) => setState(() {
    _zoom = z.clamp(1.0, 6.0);
    _pan = _clamp(_pan);
  });

  Future<void> _use() async {
    final img = _img;
    if (img == null) return;
    setState(() => _busy = true);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(_out / _view);
    CropPainter(img, _scale, _pan).paint(canvas, const Size(_view, _view));
    final out = await rec.endRecording().toImage(_out, _out);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    if (!mounted || png == null) return;
    await widget.onUse(png.buffer.asUint8List());
    if (mounted) Navigator.of(context).maybePop();
  }

  Widget _preview(AvatarShape shape, double size) => ClipRRect(
    borderRadius: shape.radius(size),
    child: SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: CropPainter(_img!, _scale * size / _view, _pan * (size / _view))),
    ),
  );

  /// No picture yet: the shape to drop one on, saying how to get one in.
  Widget _empty(AvatarShape shape, ColorScheme scheme) {
    final hot = _dropping;
    return AnimatedContainer(
      key: const ValueKey('picture-drop'),
      duration: const Duration(milliseconds: 120),
      width: _view,
      height: _view,
      decoration: BoxDecoration(
        borderRadius: shape.radius(_view),
        color: hot ? scheme.primary.withValues(alpha: 0.16) : scheme.surfaceContainerHighest,
        border: Border.all(color: hot ? scheme.primary : scheme.outlineVariant, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              hot ? Icons.file_download_outlined : Icons.add_photo_alternate_outlined,
              size: 44,
              color: hot ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              hot ? 'Drop it here' : 'Paste a picture (Ctrl+V) or drop one here',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'PNG, JPG, WebP, GIF or BMP',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editor(ui.Image img, AvatarShape shape, ColorScheme scheme) => Listener(
    onPointerSignal: (e) {
      if (e is PointerScrollEvent) _setZoom(_zoom * (e.scrollDelta.dy > 0 ? 0.93 : 1.07));
    },
    child: GestureDetector(
      onPanUpdate: (d) => setState(() => _pan = _clamp(_pan + d.delta)),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        // The dimmed surroundings stay inside this rounded square.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: _view,
            height: _view,
            child: Stack(
              children: [
                // The whole image, dimmed outside the shape.
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.3,
                    child: CustomPaint(painter: CropPainter(img, _scale, _pan, clipToView: false)),
                  ),
                ),
                ClipRRect(
                  borderRadius: shape.radius(_view),
                  child: CustomPaint(size: const Size(_view, _view), painter: CropPainter(img, _scale, _pan)),
                ),
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: shape.radius(_view),
                      border: Border.all(color: _dropping ? scheme.tertiary : scheme.primary, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// The card; the shape follows the setting live.
  Widget _card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = AvatarShape.of(context);
    final img = _img;
    const caption = TextStyle(fontSize: 11, color: Colors.grey);
    return Material(
      elevation: 16,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Your picture', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                img == null ? 'Paste, drop or browse for a picture' : 'Drag to move · scroll to zoom',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (img == null) _empty(shape, scheme) else _editor(img, shape, scheme),
                  if (img != null) ...[
                    const SizedBox(width: 24),
                    Column(
                      children: [
                        _preview(shape, 88),
                        const SizedBox(height: 4),
                        const Text('profile', style: caption),
                        const SizedBox(height: 14),
                        _preview(shape, 42),
                        const SizedBox(height: 4),
                        const Text('party', style: caption),
                        const SizedBox(height: 14),
                        _preview(shape, 24),
                        const SizedBox(height: 4),
                        const Text('chat', style: caption),
                      ],
                    ),
                  ],
                ],
              ),
              if (_error case final e?)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    e,
                    key: const ValueKey('picture-error'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
              if (img != null)
                Row(
                  children: [
                    const Icon(Icons.zoom_out, size: 18),
                    Expanded(
                      child: Slider(value: _zoom, min: 1, max: 6, onChanged: _setZoom),
                    ),
                    const Icon(Icons.zoom_in, size: 18),
                  ],
                )
              else
                const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('picture-paste'),
                          onPressed: _paste,
                          icon: const Icon(Icons.content_paste_rounded, size: 18),
                          label: const Text('Paste'),
                        ),
                        TextButton.icon(
                          key: const ValueKey('picture-browse'),
                          onPressed: _browsing ? null : _browse,
                          icon: _browsing
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.folder_open, size: 18),
                          label: Text(_browsing ? 'Choosing…' : 'Browse…'),
                        ),
                      ],
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('picture-use'),
                    onPressed: img == null || _busy ? null : _use,
                    child: const Text('Use this'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => KeyboardClaim(
    child: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: AppScope.of(context).ports.shell.dropTarget(
        onEnter: () => setState(() => _dropping = true),
        onExit: () => setState(() => _dropping = false),
        onDrop: (paths, _) => _drop(paths),
        child: SignalBuilder(builder: (context) => _card(context)),
      ),
    ),
  );
}

/// Draws [img] scaled by [scale], centred in the box and moved by [pan].
class CropPainter extends CustomPainter {
  final ui.Image img;
  final double scale;
  final Offset pan;
  final bool clipToView;
  CropPainter(this.img, this.scale, this.pan, {this.clipToView = true});

  @override
  void paint(Canvas canvas, Size size) {
    if (clipToView) canvas.clipRect(Offset.zero & size);
    final w = img.width * scale, h = img.height * scale;
    final dst = Rect.fromLTWH((size.width - w) / 2 + pan.dx, (size.height - h) / 2 + pan.dy, w, h);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(CropPainter old) => old.img != img || old.scale != scale || old.pan != pan;
}
