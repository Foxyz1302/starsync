import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/accounts_panel.dart';
import '../screens/home/about_page.dart';
import '../screens/home/settings_page.dart';
import '../update/update_controller.dart';
import 'avatar.dart';
import 'motion.dart';

/// The Settings tab's pages, in nav order.
enum SettingsSection {
  profile(Icons.person_outline, 'Profile'),
  player(Icons.play_circle_outline, 'Player'),
  integrations(Icons.extension_outlined, 'Jellyfin & integrations'),
  updates(Icons.system_update_alt, 'Updates'),
  shortcuts(Icons.keyboard_outlined, 'Keyboard shortcuts'),
  about(Icons.info_outline, 'About');

  final IconData icon;
  final String label;
  const SettingsSection(this.icon, this.label);
}

/// App-wide settings under a left nav (chips on top when narrow). The
/// pages hold the existing settings panels; the shell owns [section] so
/// the profile card can open a page.
class SettingsTab extends StatelessWidget {
  final SettingsSection section;
  final ValueChanged<SettingsSection> onSection;
  final VoidCallback? onEditProfile;
  final UpdateController? updates;
  /// Defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  const SettingsTab({
    super.key,
    required this.section,
    required this.onSection,
    this.onEditProfile,
    this.updates,
    this.jellyfin,
  });

  List<Widget> _page(BuildContext context) {
    switch (section) {
      case SettingsSection.profile:
        return [
          SettingsPanel(
            title: 'You',
            child: SignalBuilder(
              builder: (context) {
                final me = selfAvatarInfo();
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: StatusAvatar(info: me, size: 48, badges: false, ring: false),
                  title: Text(me.name == '?' ? 'No name yet' : me.name),
                  subtitle: const Text('Name, picture and colour: click your avatar in the top left'),
                  trailing: onEditProfile == null
                      ? null
                      : TextButton(onPressed: onEditProfile, child: const Text('Edit')),
                );
              },
            ),
          ),
        ];
      case SettingsSection.player:
        return const [
          SettingsPanel(
            title: 'Player',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [HwdecSetting(), SizedBox(height: 12), MpvControlsSetting()],
            ),
          ),
          SettingsPanel(title: 'Video quality & shaders', child: ShaderSettings()),
        ];
      case SettingsSection.integrations:
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: JellyfinAccountsPanel(accounts: jellyfin ?? JellyfinAccounts.instance),
          ),
          const SettingsPanel(title: 'Jellyfin playback', child: AutoAdvanceSetting()),
        ];
      case SettingsSection.updates:
        return [SettingsPanel(title: 'Updates', child: UpdateSettings(controller: updates))];
      case SettingsSection.shortcuts:
        return const [SettingsPanel(title: 'Keyboard shortcuts', child: ShortcutList())];
      case SettingsSection.about:
        return [AboutPanel(updates: updates)];
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 760;
        final nav = narrow
            ? SizedBox(
                height: 52,
                child: HScroll(
                  builder: (c) => ListView(
                    controller: c,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    children: [
                      for (final s in SettingsSection.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: ValueKey('settings-${s.name}'),
                            label: Text(s.label),
                            selected: section == s,
                            onSelected: (_) => onSection(s),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            : SizedBox(
                width: 250,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 8, 20),
                  children: [
                    for (final s in SettingsSection.values)
                      ListTile(
                        key: ValueKey('settings-${s.name}'),
                        selected: section == s,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        leading: Icon(s.icon, size: 20),
                        title: Text(s.label),
                        onTap: () => onSection(s),
                      ),
                  ],
                ),
              );
        final page = fadeThrough(
          KeyedSubtree(
            key: ValueKey(section),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 24, 24),
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(section.label, style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 14),
                        ..._page(context),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        return narrow
            ? Column(children: [nav, Expanded(child: page)])
            : Row(children: [nav, Expanded(child: page)]);
      },
    );
  }
}
