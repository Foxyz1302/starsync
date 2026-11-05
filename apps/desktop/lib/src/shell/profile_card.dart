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
  late final _p = AppScope.of(context).profile;
  late final _name = TextEditingController(text: _p.name.peek());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _open(SettingsSection s) {
    Navigator.of(context).maybePop();
    widget.onOpenSettings(s);
  }

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
          final out = self?.isOut ?? false;
          final me = selfAvatarInfo(host: hosting, presence: self?.presence ?? Presence.watching);
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
                    ProfilePicture(profile: _p, info: me, ring: online),
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
                              if (online && self != null && self.presence != Presence.watching)
                                Pill(switch (self.presence) {
                                  Presence.brb => 'BRB',
                                  Presence.afk => 'AFK',
                                  _ => 'out',
                                }, Colors.lightBlueAccent),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 4), child: ProfileColors(profile: _p)),
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
                      out ? Icons.login_rounded : Icons.visibility_off_rounded,
                      out ? 'Join' : 'Out',
                      trailing: Text(out ? 'Space' : 'nobody waits for you', style: small),
                      onTap: () {
                        out ? coord.join() : coord.goOut();
                        Navigator.of(context).maybePop();
                      },
                    ),
                  _link(
                    Icons.video_library_outlined,
                    'Library & accounts',
                    trailing: ListenableBuilder(
                      listenable: JellyfinAccounts.instance,
                      builder: (context, _) {
                        final n = JellyfinAccounts.instance.accounts.length;
                        return Text(n == 0 ? 'none' : '$n linked', style: small);
                      },
                    ),
                    onTap: () => _open(SettingsSection.library),
                  ),
                  _link(Icons.settings_outlined, 'Settings', onTap: () => _open(SettingsSection.party)),
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
                  _link(Icons.help_outline, 'Help & about', onTap: () => _open(SettingsSection.help)),
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

/// Your picture, 88 px: a hover says "Change", a click opens the
/// [CropPicker]. The profile card and the name card show it.
class ProfilePicture extends StatefulWidget {
  final Profile profile;
  final AvatarInfo info;
  final bool ring;
  const ProfilePicture({super.key, required this.profile, required this.info, this.ring = false});

  @override
  State<ProfilePicture> createState() => _ProfilePictureState();
}

class _ProfilePictureState extends State<ProfilePicture> {
  bool _hover = false;

  Future<void> _change() => showPopover<void>(
        context,
        at: Alignment.center,
        dim: true,
        child: CropPicker(onUse: widget.profile.setPicture),
      );

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const ValueKey('profile-picture'),
          onTap: _change,
          child: SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              children: [
                StatusAvatar(info: widget.info, size: 88, badges: false, marks: widget.ring),
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: easeTime,
                    curve: ease,
                    opacity: _hover ? 1 : 0,
                    child: Container(
                      decoration:
                          BoxDecoration(borderRadius: AvatarShape.of(context).radius(88), color: Colors.black54),
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
      );
}

/// "Colour" and the swatches ([profileColors]); a click picks one.
class ProfileColors extends StatelessWidget {
  final Profile profile;
  const ProfileColors({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = profile;
    return SignalBuilder(builder: (context) {
      final color = p.color.value;
      return Row(
        children: [
          Text('Colour', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const Spacer(),
          for (final c in profileColors)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => p.setColor(c),
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
      );
    });
  }
}

/// A join with no name yet stops here first: "Wait, what do we call
/// you?" with the profile card's picture and colours and a name field
/// (the computer's user name to start with). OK saves the name and the
/// join goes on (true); Cancel, Esc or a click outside drop it.
Future<bool> askYourName(BuildContext context, Profile profile) async =>
    await showPopover<bool>(context, at: Alignment.center, dim: true, child: NameCard(profile: profile)) ?? false;

class NameCard extends StatefulWidget {
  final Profile profile;
  /// The name to start with (default: [suggestedName]).
  final String? suggestion;
  const NameCard({super.key, required this.profile, this.suggestion});

  @override
  State<NameCard> createState() => _NameCardState();
}

class _NameCardState extends State<NameCard> {
  late final _p = widget.profile;
  late final _name = TextEditingController(text: widget.suggestion ?? suggestedName());

  @override
  void initState() {
    super.initState();
    _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    _p.setName(name);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('name-card'),
      elevation: 12,
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        child: ListenableBuilder(
          listenable: _name,
          builder: (context, _) => SignalBuilder(builder: (context) {
            final color = _p.color.value;
            final typed = _name.text.trim();
            // Your picture, else the initial of the name being typed.
            final me = AvatarInfo(name: typed.isEmpty ? '?' : typed, color: color, image: selfAvatarInfo().image);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedContainer(
                  duration: easeTime,
                  curve: ease,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0.08)],
                    ),
                  ),
                  child: Row(
                    children: [
                      ProfilePicture(profile: _p, info: me),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Wait, what do we call you?', style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            TextField(
                              key: const ValueKey('name-card-name'),
                              controller: _name,
                              autofocus: true,
                              maxLength: 32,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                              decoration: const InputDecoration(
                                isDense: true,
                                counterText: '',
                                hintText: 'Your name',
                              ),
                              onSubmitted: (_) => _ok(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 0), child: ProfileColors(profile: _p)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Text('Others see your name and picture. You can change them later from your avatar.',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 16, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const ValueKey('name-card-cancel'),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('name-card-ok'),
                        onPressed: typed.isEmpty ? null : _ok,
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
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
