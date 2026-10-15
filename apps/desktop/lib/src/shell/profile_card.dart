import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show Presence;

import '../jellyfin/accounts.dart';
import '../session/identity.dart';
import '../app/app_graph.dart';
import '../update/update_controller.dart';
import 'avatar.dart';
import 'motion.dart';
import 'settings_tab.dart' show SettingsSection;

/// Your profile, from your avatar in the strip: name and picture apply
/// live (pushed to the server while in one), colour is yours only; links
/// to the app-wide pages.
Future<void> showProfileCard(
  BuildContext context, {
  required ValueChanged<SettingsSection> onOpenSettings,
  UpdateController? updates,
}) =>
    showPopover<void>(
      context,
      at: const Alignment(-0.97, -0.84),
      child: ProfileCard(onOpenSettings: onOpenSettings, updates: updates),
    );

class ProfileCard extends StatefulWidget {
  final ValueChanged<SettingsSection> onOpenSettings;
  final UpdateController? updates;
  const ProfileCard({super.key, required this.onOpenSettings, this.updates});

  @override
  State<ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<ProfileCard> {
  final _p = Profile.instance;
  late final _name = TextEditingController(text: _p.name.peek());
  bool _hoverPic = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _open(SettingsSection s) {
    Navigator.of(context).maybePop();
    widget.onOpenSettings(s);
  }

  Future<void> _changePicture() => showPopover<void>(
        context,
        at: Alignment.center,
        dim: true,
        child: CropPicker(onUse: _p.setPicture),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return Material(
      elevation: 12,
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        child: SignalBuilder(builder: (context) {
          final graph = AppScope.of(context);
          final coord = graph.coordinator;
          // Alone it is a plain player: no ring, no crown.
          final online = graph.navigation.online.value && !coord.alone.value;
          final self = online ? coord.selfMember.value : null;
          final hosting = online && graph.navigation.home.value;
          final color = _p.color.value;
          final png = _p.picture.value;
          final out = self?.presence == Presence.away;
          final me = selfAvatarInfo(ready: self?.ready ?? false, host: hosting, presence: self?.presence ?? Presence.watching);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header tinted with your colour.
              AnimatedContainer(
                duration: easeTime,
                curve: ease,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0.08)],
                  ),
                ),
                child: Row(
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _hoverPic = true),
                      onExit: (_) => setState(() => _hoverPic = false),
                      child: GestureDetector(
                        key: const ValueKey('profile-picture'),
                        onTap: _changePicture,
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: Stack(
                            children: [
                              StatusAvatar(info: me, size: 88, badges: false, ring: online),
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  duration: easeTime,
                                  curve: ease,
                                  opacity: _hoverPic ? 1 : 0,
                                  child: Container(
                                    margin: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.photo_camera_outlined, color: Colors.white, size: 22),
                                        Text('Change', style: TextStyle(color: Colors.white, fontSize: 11)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            key: const ValueKey('profile-name'),
                            controller: _name,
                            maxLength: 32,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                            decoration: const InputDecoration(
                              isDense: true,
                              counterText: '',
                              border: InputBorder.none,
                              hintText: 'Your name',
                              suffixIcon: Icon(Icons.edit_outlined, size: 16),
                              suffixIconConstraints: BoxConstraints(minWidth: 20),
                            ),
                            onChanged: _p.setName,
                            onSubmitted: (_) => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (hosting) const Pill('host', Colors.amber),
                              Pill(online ? 'with others' : 'just you',
                                  online ? Colors.greenAccent : Colors.grey),
                              if (online)
                                Pill(out ? 'sitting out' : (self?.ready ?? false) ? 'ready' : 'not ready',
                                    Colors.lightBlueAccent),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Row(
                  children: [
                    Text('Colour', style: small),
                    const Spacer(),
                    for (final c in profileColors)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _p.setColor(c),
                          child: AnimatedContainer(
                            duration: easeTime,
                            curve: ease,
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: color.toARGB32() == c.toARGB32() ? scheme.onSurface : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (png != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text('PNG · ${(png.length / 1024).toStringAsFixed(0)} KB', style: small),
                      const Spacer(),
                      TextButton(onPressed: () => _p.setPicture(null), child: const Text('Remove picture')),
                    ],
                  ),
                ),
              if (_p.error.value case final err?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(err, style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(
                  online
                      ? 'Name and picture update for everyone in the server right away. Colour is yours only.'
                      : 'Others see your name and picture when they join you or you join them. Colour is yours only.',
                  style: small,
                ),
              ),
              const Padding(padding: EdgeInsets.fromLTRB(12, 12, 12, 0), child: Divider(height: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [
                  if (self != null)
                    _link(
                      out ? Icons.login_rounded : Icons.event_seat_outlined,
                      out ? 'Join back' : 'Sit out',
                      trailing: Text(out ? 'Space' : 'stay in the server', style: small),
                      onTap: () {
                        out ? coord.joinBack() : coord.sitOut();
                        Navigator.of(context).maybePop();
                      },
                    ),
                  _link(
                    Icons.extension_outlined,
                    'Jellyfin & integrations',
                    trailing: ListenableBuilder(
                      listenable: JellyfinAccounts.instance,
                      builder: (context, _) {
                        final n = JellyfinAccounts.instance.accounts.length;
                        return Text(n == 0 ? 'none' : '$n linked', style: small);
                      },
                    ),
                    onTap: () => _open(SettingsSection.integrations),
                  ),
                  _link(Icons.settings_outlined, 'Settings', onTap: () => _open(SettingsSection.profile)),
                  ValueListenableBuilder(
                    valueListenable: (widget.updates ?? UpdateController.instance).status,
                    builder: (context, s, _) {
                      final m = s.manifest;
                      final available = s.phase != UpdatePhase.idle && m != null;
                      return _link(
                        Icons.system_update_alt,
                        available ? 'Update to ${m.version}' : 'Updates',
                        trailing: available ? Pill('new', Colors.greenAccent.shade400) : null,
                        onTap: () => _open(SettingsSection.updates),
                      );
                    },
                  ),
                  _link(Icons.info_outline, 'About', onTap: () => _open(SettingsSection.about)),
                ]),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _link(IconData icon, String label, {Widget? trailing, required VoidCallback onTap}) => ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        leading: Icon(icon, size: 20),
        title: Text(label),
        trailing: trailing,
        onTap: onTap,
      );
}

/// Avatar crop: pick a file, drag to move, scroll or slide to zoom; live
/// previews at the sizes it is shown. "Use this" renders a 256 px PNG.
class CropPicker extends StatefulWidget {
  final Future<void> Function(Uint8List png) onUse;

  /// Opens the file dialog right away (that is why the picker opened).
  final bool autoPick;
  const CropPicker({super.key, required this.onUse, this.autoPick = true});

  @override
  State<CropPicker> createState() => _CropPickerState();
}

class _CropPickerState extends State<CropPicker> {
  static const _view = 300.0, _out = 256;
  ui.Image? _img;
  double _zoom = 1; // 1 = the image just covers the circle
  Offset _pan = Offset.zero; // in viewport pixels
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPick) WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final List<String> files;
    try {
      files = await AppScope.of(context).ports.folders.pickFiles(
        dialogTitle: 'Pick a picture',
        extensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'file dialog unavailable — try again');
      return;
    }
    final path = files.firstOrNull;
    if (path == null) return;
    try {
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      _img?.dispose();
      setState(() {
        _img = frame.image;
        _zoom = 1;
        _pan = Offset.zero;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'could not read that image');
    }
  }

  double get _scale {
    final img = _img!;
    return math.max(_view / img.width, _view / img.height) * _zoom;
  }

  /// Keeps the circle covered: the image edge never shows inside it.
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

  Widget _preview(double size) => ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: CropPainter(_img!, _scale * size / _view, _pan * (size / _view))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = _img;
    const caption = TextStyle(fontSize: 11, color: Colors.grey);
    final editor = img == null
        ? InkWell(
            customBorder: const CircleBorder(),
            onTap: _pick,
            child: Container(
              width: _view,
              height: _view,
              decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined, size: 48, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text(_error ?? 'Choose a picture', style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          )
        : Listener(
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
                        // The whole image, dimmed outside the circle.
                        Positioned.fill(
                          child: Opacity(
                            opacity: 0.3,
                            child: CustomPaint(painter: CropPainter(img, _scale, _pan, clipToView: false)),
                          ),
                        ),
                        ClipOval(
                          child: CustomPaint(size: const Size(_view, _view), painter: CropPainter(img, _scale, _pan)),
                        ),
                        IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.primary, width: 2),
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
                img == null ? 'PNG, JPG, WebP, GIF or BMP' : 'Drag to move · scroll to zoom',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  editor,
                  if (img != null) ...[
                    const SizedBox(width: 24),
                    Column(
                      children: [
                        _preview(88),
                        const SizedBox(height: 4),
                        const Text('profile', style: caption),
                        const SizedBox(height: 14),
                        _preview(42),
                        const SizedBox(height: 4),
                        const Text('party', style: caption),
                        const SizedBox(height: 14),
                        _preview(24),
                        const SizedBox(height: 4),
                        const Text('chat', style: caption),
                      ],
                    ),
                  ],
                ],
              ),
              if (img != null)
                Row(
                  children: [
                    const Icon(Icons.zoom_out, size: 18),
                    Expanded(child: Slider(value: _zoom, min: 1, max: 6, onChanged: _setZoom)),
                    const Icon(Icons.zoom_in, size: 18),
                  ],
                )
              else
                const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(img == null ? 'Choose…' : 'Other file…'),
                  ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: img == null || _busy ? null : _use, child: const Text('Use this')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
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
