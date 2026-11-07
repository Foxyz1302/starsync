
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show Presence;

import '../jellyfin/accounts.dart';
import '../session/identity.dart';
import '../app/app_graph.dart';
import '../update/update_controller.dart';
import 'avatar.dart';
import 'motion.dart';
import 'picture_picker.dart';
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
/// [CropPicker]. Without a picture (your initial) a camera badge in the
/// corner says one can be added. The profile card and the name card show
/// it.
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final none = widget.info.image == null;
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
            width: 88,
            height: 88,
            child: Stack(
              clipBehavior: Clip.none,
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.photo_camera_outlined, color: Colors.white, size: 22),
                          Text(none ? 'Add' : 'Change', style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (none)
                  Positioned(
                    key: const ValueKey('profile-picture-add'),
                    top: -4,
                    right: -4,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surfaceContainer, width: 2),
                      ),
                      child: Icon(Icons.add_a_photo_outlined, size: 15, color: scheme.onPrimary),
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
