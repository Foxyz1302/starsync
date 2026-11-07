import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:signals/signals_flutter.dart';

import '../session/identity.dart';
import 'avatar.dart';
import 'color_picker.dart';
import 'motion.dart';
import 'picture_picker.dart';

// The parts of a person card that are yours to change: on your own card
// (the profile card, a pinned card of yours, Settings → Party → You) the
// picture, the name and the colour edit in place; the name card ("Wait,
// what do we call you?") uses the picture and the colours too. Each change
// is live ([Profile]).

/// Your picture: a hover says "Change", a click opens the [CropPicker].
/// Without a picture (your initial) a camera badge in the corner says one
/// can be added.
class ProfilePicture extends StatefulWidget {
  final Profile profile;
  final AvatarInfo info;
  final double size;

  /// The standing and activity on its edge (with others).
  final bool ring;
  const ProfilePicture({super.key, required this.profile, required this.info, this.size = 64, this.ring = false});

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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final none = widget.info.image == null;
    final size = widget.size;
    final badge = (size * 0.36).clamp(22.0, 28.0);
    return Tooltip(
      message: none ? 'Add a picture' : 'Change your picture',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const ValueKey('profile-picture'),
          onTap: _change,
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                StatusAvatar(info: widget.info, size: size, badges: widget.ring, marks: widget.ring),
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: easeTime,
                    curve: ease,
                    opacity: _hover ? 1 : 0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: AvatarShape.of(context).radius(size),
                        color: Colors.black54,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.photo_camera_outlined, color: Colors.white, size: size * 0.28),
                          Text(none ? 'Add' : 'Change', style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (none)
                  Positioned(
                    key: const ValueKey('profile-picture-add'),
                    top: -5,
                    right: -5,
                    child: Container(
                      width: badge,
                      height: badge,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF18181C), width: 2),
                      ),
                      child: Icon(Icons.add_a_photo_outlined, size: badge * 0.54, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Your name where a card shows it, edited in place: it reads as the
/// name, a pencil says it can change, a click puts the cursor in it.
/// Live ([Profile.setName]); emptied, it shows the name again when left.
class ProfileName extends StatefulWidget {
  final Profile profile;
  final TextStyle? style;

  /// Enter: the card is done (a popup closes).
  final VoidCallback? onSubmitted;
  const ProfileName({super.key, required this.profile, this.style, this.onSubmitted});

  @override
  State<ProfileName> createState() => _ProfileNameState();
}

class _ProfileNameState extends State<ProfileName> {
  late final _name = TextEditingController(text: widget.profile.name.peek());
  final _focus = FocusNode(debugLabel: 'profile name');
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _name.text.trim().isEmpty) _name.text = widget.profile.name.peek();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = _focus.hasFocus;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Esc while typing: a popup card closes (as on Enter), else the
      // field lets go.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              widget.onSubmitted == null ? _focus.unfocus() : widget.onSubmitted!(),
        },
        child: TextField(
          controller: _name,
          focusNode: _focus,
          maxLength: 32,
          style: widget.style,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: 'Your name',
            contentPadding: const EdgeInsets.symmetric(vertical: 3),
            border: InputBorder.none,
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(
                color: _hover ? scheme.onSurfaceVariant.withValues(alpha: 0.5) : Colors.transparent,
              ),
            ),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: scheme.primary, width: 1.5)),
            suffixIcon: Icon(
              Icons.edit_outlined,
              size: 15,
              color: editing || _hover ? scheme.onSurface : scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 22, minHeight: 16),
          ),
          onChanged: widget.profile.setName,
          onSubmitted: (_) => widget.onSubmitted?.call(),
        ),
      ),
    );
  }
}

/// Your colour: the swatches ([profileColors]), the one you made when it
/// is none of them, and "Custom…", which opens the [ColorPicker] in place
/// for any colour. A click picks; every change is live.
class ProfileColors extends StatefulWidget {
  final Profile profile;
  const ProfileColors({super.key, required this.profile});

  static const swatch = 22.0;

  @override
  State<ProfileColors> createState() => _ProfileColorsState();
}

class _ProfileColorsState extends State<ProfileColors> {
  bool _custom = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.profile;
    return SignalBuilder(
      builder: (context) {
        final color = p.color.value;
        final own = !profileColors.any((c) => c.toARGB32() == color.toARGB32());
        Widget swatch(Color c, {Key? key, String? tip}) {
          final on = c.toARGB32() == color.toARGB32();
          final dot = InkWell(
            key: key,
            customBorder: const CircleBorder(),
            onTap: () => p.setColor(c),
            child: AnimatedContainer(
              duration: easeTime,
              curve: ease,
              width: ProfileColors.swatch,
              height: ProfileColors.swatch,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: on ? scheme.onSurface : Colors.white.withValues(alpha: 0.16),
                  width: on ? 2 : 1,
                ),
              ),
            ),
          );
          return Padding(
            padding: const EdgeInsets.only(right: 7),
            child: tip == null ? dot : Tooltip(message: tip, child: dot),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    runSpacing: 6,
                    children: [
                      for (final c in profileColors) swatch(c),
                      if (own)
                        swatch(color, key: const ValueKey('color-own'), tip: 'Your colour, ${colorToWire(color)}'),
                    ],
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('color-custom'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: scheme.onSurface,
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5),
                  ),
                  onPressed: () => setState(() => _custom = !_custom),
                  icon: Icon(_custom ? Icons.expand_less_rounded : Icons.palette_outlined, size: 16),
                  label: const Text('Custom…'),
                ),
              ],
            ),
            AnimatedSize(
              duration: easeTime,
              curve: ease,
              alignment: Alignment.topCenter,
              child: _custom
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ColorPicker(value: color, onChanged: p.setColor),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        );
      },
    );
  }
}
