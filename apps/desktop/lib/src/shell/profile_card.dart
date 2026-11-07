import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../jellyfin/accounts.dart';
import '../session/identity.dart';
import '../update/update_controller.dart';
import 'avatar.dart';
import 'motion.dart';
import 'person_card.dart';
import 'profile_edit.dart';
import 'settings_tab.dart' show SettingsSection;

/// Your profile, from your avatar in the strip: your own person card, the
/// same as everyone's, with the picture, name and colour edited in place
/// (live, pushed to the server while in one), then links to the app-wide
/// pages.
Future<void> showProfileCard(
  BuildContext context, {
  required ValueChanged<SettingsSection> onOpenSettings,
  UpdateController? updates,
}) => showPopover<void>(
  context,
  at: const Alignment(-0.97, -0.84),
  child: ProfileCard(onOpenSettings: onOpenSettings, updates: updates),
);

class ProfileCard extends StatelessWidget {
  final ValueChanged<SettingsSection> onOpenSettings;
  final UpdateController? updates;
  const ProfileCard({super.key, required this.onOpenSettings, this.updates});

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    void open(SettingsSection s) {
      Navigator.of(context).maybePop();
      onOpenSettings(s);
    }

    Widget link(IconData icon, String label, {Widget? trailing, required VoidCallback onTap}) => ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, size: 20),
      title: Text(label),
      trailing: trailing,
      onTap: onTap,
    );
    return PersonCard.you(
      onDone: () => Navigator.of(context).maybePop(),
      footer: [
        link(
          Icons.video_library_outlined,
          'Library & accounts',
          trailing: ListenableBuilder(
            listenable: JellyfinAccounts.instance,
            builder: (context, _) {
              final n = JellyfinAccounts.instance.accounts.length;
              return Text(n == 0 ? 'none' : '$n linked', style: small);
            },
          ),
          onTap: () => open(SettingsSection.library),
        ),
        link(Icons.settings_outlined, 'Settings', onTap: () => open(SettingsSection.party)),
        ValueListenableBuilder(
          valueListenable: (updates ?? UpdateController.instance).status,
          builder: (context, s, _) {
            final m = s.manifest;
            final available = s.phase != UpdatePhase.idle && m != null;
            return link(
              Icons.system_update_alt,
              available ? 'Update to ${m.version}' : 'Updates',
              trailing: available ? Pill('new', Colors.greenAccent.shade400) : null,
              onTap: () => open(SettingsSection.updates),
            );
          },
        ),
        link(Icons.help_outline, 'Help & about', onTap: () => open(SettingsSection.help)),
      ],
    );
  }
}

/// A join with no name yet stops here first: "Wait, what do we call
/// you?" on a card like your own person card (the same tint, picture and
/// colours) with a plain name field (the computer's user name to start
/// with). OK saves the name and the join goes on (true); Cancel, Esc or a
/// click outside drop it.
Future<bool> askYourName(BuildContext context, Profile profile) async =>
    await showPopover<bool>(
      context,
      at: Alignment.center,
      dim: true,
      child: NameCard(profile: profile),
    ) ??
    false;

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
    return SignalBuilder(
      builder: (context) => PersonCardFrame(
        key: const ValueKey('name-card'),
        tint: _p.color.value,
        child: ListenableBuilder(
          listenable: _name,
          builder: (context, _) => SignalBuilder(
            builder: (context) {
              final color = _p.color.value;
              final typed = _name.text.trim();
              // Your picture, else the initial of the name being typed.
              final me = AvatarInfo(name: typed.isEmpty ? '?' : typed, color: color, image: selfAvatarInfo().image);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            ProfilePicture(profile: _p, info: me, size: PersonCard.pictureSize),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Wait, what do we call you?', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 4),
                                  TextField(
                                    key: const ValueKey('name-card-name'),
                                    controller: _name,
                                    autofocus: true,
                                    maxLength: 32,
                                    style: PersonCardView.nameStyle,
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
                        const SizedBox(height: 12),
                        ProfileColors(profile: _p),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
                    child: Text(
                      'Others see your name, picture and colour. You can change them later from your avatar.',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
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
            },
          ),
        ),
      ),
    );
  }
}
