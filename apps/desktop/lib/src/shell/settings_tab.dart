import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../controls/player_settings.dart';
import '../jellyfin/accounts.dart';
import '../jellyfin/accounts_panel.dart';
import '../schedule/animeflow.dart';
import '../screens/home/about_page.dart';
import '../screens/home/settings_page.dart';
import '../sfx/sfx.dart';
import '../sfx/sound_bank.dart';
import '../sfx/synth_sfx.dart';
import '../state/session_state.dart';
import '../state/settings.dart';
import '../update/update_controller.dart';
import 'avatar.dart';
import 'motion.dart';

/// The Settings tab's pages, in nav order.
enum SettingsSection {
  profile(Icons.person_outline, 'Profile'),
  network(Icons.hub_outlined, 'Party & network'),
  player(Icons.play_circle_outline, 'Player'),
  integrations(Icons.extension_outlined, 'Jellyfin & integrations'),
  notifications(Icons.notifications_none, 'Notifications & sounds'),
  updates(Icons.system_update_alt, 'Updates'),
  shortcuts(Icons.keyboard_outlined, 'Keyboard shortcuts'),
  about(Icons.info_outline, 'About');

  final IconData icon;
  final String label;
  const SettingsSection(this.icon, this.label);
}

/// App-wide settings under a left nav (chips on top when narrow), each
/// page a column of cards; the shell owns [section] so the profile card
/// can open a page.
class SettingsTab extends StatelessWidget {
  final SettingsSection section;
  final ValueChanged<SettingsSection> onSection;
  final VoidCallback? onEditProfile;
  final UpdateController? updates;
  /// Defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  /// AnimeFlow's `/me` for the integrations page (tests pass a fake).
  final Future<AnimeFlowMe> Function()? animeFlowMe;
  const SettingsTab({
    super.key,
    required this.section,
    required this.onSection,
    this.onEditProfile,
    this.updates,
    this.jellyfin,
    this.animeFlowMe,
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
      case SettingsSection.network:
        return [
          const HostDefaultsPanel(),
          const RecentServersPanel(),
          SettingsPanel(
            title: 'Watching',
            child: SignalBuilder(
              builder: (context) => SwitchListTile(
                key: const ValueKey('unready-on-swap'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Unready when the video changes'),
                subtitle: const Text('Otherwise you stay ready and the next video starts once everyone ready has buffered'),
                value: AppSettings.instance.unreadyOnSwap.value,
                onChanged: AppSettings.instance.setUnreadyOnSwap,
              ),
            ),
          ),
        ];
      case SettingsSection.player:
        return [
          const SettingsHintCard(
            icon: Icons.tune,
            text: "Player settings are also in the player's ⚙, at the right end of its controls.",
          ),
          SettingsPanel(
            title: 'Player',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: playerSettingRows()),
          ),
          const SettingsPanel(title: 'Custom shaders', child: CustomShaderFiles()),
        ];
      case SettingsSection.integrations:
        final accounts = jellyfin ?? JellyfinAccounts.instance;
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: JellyfinAccountsPanel(accounts: accounts),
          ),
          AnimeFlowCard(
            me: animeFlowMe ??
                () async {
                  final client = AnimeFlowClient.fromAccounts(accounts);
                  try {
                    return await client.me();
                  } finally {
                    client.close();
                  }
                },
          ),
          const SettingsPanel(title: 'Jellyfin playback', child: AutoAdvanceSetting()),
          const SettingsPanel(title: 'Jellyfin library', child: HideReReleasesSetting()),
        ];
      case SettingsSection.notifications:
        return const [NotificationsInfo()];
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
                            avatar: Icon(s.icon, size: 18),
                            showCheckmark: false,
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

/// Party & network: what the Host card starts with.
class HostDefaultsPanel extends StatefulWidget {
  const HostDefaultsPanel({super.key});

  @override
  State<HostDefaultsPanel> createState() => _HostDefaultsPanelState();
}

class _HostDefaultsPanelState extends State<HostDefaultsPanel> {
  final _form = SessionState.instance.lastForm;
  late final _port = TextEditingController(text: _form.hostPort);
  late final _secret = TextEditingController(text: _form.hostSecret);
  bool _show = false;

  @override
  void dispose() {
    _port.dispose();
    _secret.dispose();
    super.dispose();
  }

  static String? portProblem(String v) {
    final n = int.tryParse(v.trim());
    return n == null || n < 1 || n > 65535 ? 'A number from 1 to 65535' : null;
  }

  Future<void> _save() async {
    try {
      await SessionState.instance.saveForm();
    } catch (e) {
      debugPrint('save host defaults failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPanel(
      title: 'Hosting',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingRow(
            label: 'Default port',
            help: 'Where your server listens when you host; friends dial it',
            control: SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('host-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(isDense: true, errorText: portProblem(_port.text)),
                onChanged: (v) {
                  setState(() {});
                  if (portProblem(v) != null) return;
                  _form.hostPort = v.trim();
                  _save();
                },
              ),
            ),
          ),
          SettingRow(
            label: 'Password',
            help: 'Asked of everyone joining your server; blank lets in anyone who reaches the port',
            control: SizedBox(
              width: 220,
              child: TextField(
                key: const ValueKey('host-secret'),
                controller: _secret,
                obscureText: !_show,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'none',
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Hide' : 'Show',
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 18),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
                onChanged: (v) {
                  _form.hostSecret = v;
                  _save();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Party & network: the servers Join offers in one click.
class RecentServersPanel extends StatelessWidget {
  const RecentServersPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsPanel(
      title: 'Recent servers',
      child: SignalBuilder(builder: (context) {
        final list = session.recents.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Join and Host offer these in one click; remove the ones you no longer use',
                style: TextStyle(color: muted, fontSize: 12)),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('None yet.', style: TextStyle(color: muted)),
              ),
            for (final r in list)
              ListTile(
                key: ValueKey('recent-${r.key}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(r.hosted ? Icons.cast_outlined : Icons.dns_outlined),
                title: Text(r.hosted ? 'Hosted on port ${r.port}' : '${r.host}:${r.port}'),
                subtitle: r.secret.isEmpty ? null : const Text('password saved'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => session.forgetServer(r),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// AnimeFlow (the Schedule tab's source): connected as whom, with which
/// rights, or why not.
class AnimeFlowCard extends StatefulWidget {
  final Future<AnimeFlowMe> Function() me;
  const AnimeFlowCard({super.key, required this.me});

  @override
  State<AnimeFlowCard> createState() => _AnimeFlowCardState();
}

class _AnimeFlowCardState extends State<AnimeFlowCard> {
  late Future<AnimeFlowMe> _me = widget.me();

  static String scopeText(Set<AnimeFlowScope> scopes) => [
        if (scopes.contains(AnimeFlowScope.view)) 'can view',
        if (scopes.contains(AnimeFlowScope.request)) 'request',
        if (scopes.contains(AnimeFlowScope.manage)) 'approve',
      ].join(', ');

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsPanel(
      title: 'AnimeFlow',
      child: FutureBuilder<AnimeFlowMe>(
        future: _me,
        builder: (context, snap) {
          final String status;
          final Color color;
          if (snap.connectionState != ConnectionState.done) {
            status = 'checking…';
            color = muted;
          } else if (snap.hasError) {
            final e = snap.error;
            status = e is AnimeFlowException ? e.detail : '$e';
            color = Theme.of(context).colorScheme.error;
          } else {
            final me = snap.data!;
            final scopes = scopeText(me.scopes);
            status = ['connected as ${me.name.isEmpty ? me.userId : me.name}', if (scopes.isNotEmpty) scopes]
                .join(' · ');
            color = Colors.greenAccent.shade400;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.downloading_outlined),
                title: Text(Uri.parse(animeFlowDefaultBase).host),
                subtitle: Text(status, key: const ValueKey('animeflow-status'), style: TextStyle(color: color)),
                trailing: TextButton(
                  onPressed: snap.connectionState == ConnectionState.done
                      ? () => setState(() => _me = widget.me())
                      : null,
                  child: const Text('Check again'),
                ),
              ),
              Text(
                'Powers the Schedule tab: what is downloaded, downloading or missing, and requests. '
                'Signs in with your Jellyfin account on the same domain.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What pops up and what makes a sound. No switches: there is nothing to
/// choose yet.
class NotificationsInfo extends StatelessWidget {
  const NotificationsInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    Widget line(String title, String help) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(title), Text(help, style: muted)],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPanel(
          title: 'Pop-ups',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              line('Joins, leaves, kicks, video changes and chat',
                  'Pop up bottom left for 5 s, with the person\'s picture'),
              line('Ready, seeks and pauses', 'Only in Chat & activity (Tab), never as a pop-up'),
              line('App notices', 'Shader changes, a frozen video reloaded, the idle warning'),
            ],
          ),
        ),
        const SettingsPanel(title: 'Sounds', child: SoundSettings()),
      ],
    );
  }
}

/// Volume, then every sound with a preview button and its own switch.
class SoundSettings extends StatelessWidget {
  const SoundSettings({super.key});

  void _preview(SfxKind kind) {
    final sfx = SessionState.instance.sfx;
    if (sfx is SynthSfx) unawaited(sfx.preview(kind, readyIndex: 2));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return SignalBuilder(builder: (context) {
      final volume = s.soundVolume.value;
      final off = s.soundsOff.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(volume == 0 ? Icons.volume_off_outlined : Icons.volume_down_outlined,
                  color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  key: const ValueKey('sound-volume'),
                  value: volume,
                  onChanged: s.setSoundVolume,
                  onChangeEnd: (_) => _preview(SfxKind.ready),
                ),
              ),
              SizedBox(width: 44, child: Text('${(volume * 100).round()}%', textAlign: TextAlign.end)),
            ],
          ),
          Text('Soft cues for people and readiness; the video itself covers play, pause and the end. '
              'Letting go of the slider plays the ready sound.', style: muted),
          const SizedBox(height: 8),
          for (final MapEntry(key: kind, value: (name, help)) in soundInfo.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    key: ValueKey('sound-play-${kind.name}'),
                    tooltip: 'Play',
                    onPressed: volume == 0 ? null : () => _preview(kind),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text(name), Text(help, style: muted)],
                    ),
                  ),
                  Switch(
                    key: ValueKey('sound-on-${kind.name}'),
                    value: !off.contains(kind.name),
                    onChanged: volume == 0 ? null : (on) => s.setSoundOn(kind.name, on),
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }
}
