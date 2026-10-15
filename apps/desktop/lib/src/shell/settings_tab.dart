import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart'
    show CookieBrowser, CookieFile, NetscapeCookie, YtDlp, YtDlpCookies, cookieBrowsers, parseCookies;

import '../controls/player_settings.dart';
import '../jellyfin/accounts.dart';
import '../jellyfin/accounts_panel.dart';
import '../schedule/animeflow.dart';
import '../screens/home/about_page.dart';
import '../screens/home/settings_page.dart';
import '../screens/home/ui.dart' show appName, displayVersion;
import '../session/auto_sit_out.dart' show AutoSitOutTimes;
import '../sfx/sfx.dart';
import '../sfx/sound_bank.dart';
import '../app/app_graph.dart';
import '../state/settings.dart';
import '../update/update_controller.dart';
import '../widgets/app_menu.dart';
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
          const YourServerPanel(),
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
          SettingsPanel(
            title: 'Away',
            child: SignalBuilder(
              builder: (context) => SwitchListTile(
                key: const ValueKey('auto-sit-out'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto sit-out'),
                subtitle: Text('Idle for ${AutoSitOutTimes.idle.inMinutes} min while nothing plays, or minimised '
                    'for ${AutoSitOutTimes.minimised.inMinutes} min, sits you out so nobody waits for you; '
                    "you're back as soon as you return. Never when you're alone"),
                value: AppSettings.instance.autoSitOut.value,
                onChanged: AppSettings.instance.setAutoSitOut,
              ),
            ),
          ),
        ];
      case SettingsSection.player:
        return [
          const SettingsHintCard(
            icon: Icons.tune,
            text: "Player settings are also in the player: ⚙ → Player settings, at the right of its controls.",
          ),
          SettingsPanel(
            title: 'Player',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: playerSettingRows()),
          ),
          SettingsPanel(
            title: 'Controls',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: controlsSettingRows()),
          ),
          const SettingsPanel(title: 'Custom shaders', child: CustomShaderFiles()),
          const SettingsPanel(title: 'yt-dlp', child: YtDlpSettings()),
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
          const SettingsPanel(title: 'Episodes', child: AutoAdvanceSetting()),
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
                        // The version, quietly (also the Settings tab's
                        // tooltip and About).
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SelectableText(
                            '$appName ${displayVersion()}',
                            key: const ValueKey('settings-version'),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
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

/// Party & network: your server's port and password, used when you
/// Invite (the next time sharing starts).
class YourServerPanel extends StatefulWidget {
  const YourServerPanel({super.key});

  @override
  State<YourServerPanel> createState() => _YourServerPanelState();
}

class _YourServerPanelState extends State<YourServerPanel> {
  late final _forms = AppScope.of(context).forms;
  late final _form = _forms.form;
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
      await _forms.save();
    } catch (e) {
      debugPrint('save your server settings failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPanel(
      title: 'Your server',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingRow(
            label: 'Port',
            help: 'Where friends reach your server once you Invite (the next time you start sharing)',
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
            help: 'Asked of every friend joining your server; blank lets in anyone who reaches the port '
                '(the next time you start sharing)',
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
    final forms = AppScope.of(context).forms;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SettingsPanel(
      title: 'Recent servers',
      child: SignalBuilder(builder: (context) {
        final list = forms.recents.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Join offers these in one click; remove the ones you no longer use',
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
                leading: const Icon(Icons.dns_outlined),
                title: Text('${r.host}:${r.port}'),
                subtitle: r.secret.isEmpty ? null : const Text('password saved'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => forms.forget(r),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// The app's yt-dlp (web page links): its version, "Update now", and the
/// last error.
class YtDlpSettings extends StatefulWidget {
  /// Defaults to the app's ([Ports.links]).
  final Future<YtDlp>? ytDlp;
  const YtDlpSettings({super.key, this.ytDlp});

  @override
  State<YtDlpSettings> createState() => _YtDlpSettingsState();
}

class _YtDlpSettingsState extends State<YtDlpSettings> {
  late final Future<YtDlp> _y = widget.ytDlp ?? AppScope.of(context).ports.links.ytDlp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<YtDlp>(
      future: _y,
      builder: (context, snap) {
        final y = snap.data;
        if (y == null) return const SizedBox.shrink();
        return StreamBuilder<void>(
          stream: y.changes,
          builder: (context, _) {
            final err = y.lastError;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.travel_explore),
                  title: Text(y.busy
                      ? 'Downloading…'
                      : y.version == null
                          ? 'Not downloaded yet'
                          : 'Version ${y.version}'),
                  subtitle: err == null
                      ? null
                      : Text(err, key: const ValueKey('ytdlp-error'), style: TextStyle(color: scheme.error)),
                  trailing: TextButton(
                    onPressed: y.busy
                        ? null
                        : () => y.path == null ? y.ensure() : y.update(force: true),
                    child: const Text('Update now'),
                  ),
                ),
                Text(
                  'Plays links to web pages (YouTube, X, …) in all three link modes. '
                  'Downloaded and kept up to date by the app; checked once a day.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 12),
                YtDlpCookieSettings(cookies: y.cookies),
              ],
            );
          },
        );
      },
    );
  }
}

/// yt-dlp's cookies (sites that refuse guests): from a browser, or a
/// cookies.txt / JSON export picked or dropped, filtered by site into the
/// private copy in the yt-dlp folder (see [YtDlpCookies]).
class YtDlpCookieSettings extends StatefulWidget {
  final YtDlpCookies cookies;
  const YtDlpCookieSettings({super.key, required this.cookies});

  @override
  State<YtDlpCookieSettings> createState() => _YtDlpCookieSettingsState();
}

class _YtDlpCookieSettingsState extends State<YtDlpCookieSettings> {
  late var _source = widget.cookies.read();
  String? _error;
  bool _dragging = false;

  void _reload([String? error]) {
    if (!mounted) return;
    setState(() {
      _source = widget.cookies.read();
      _error = error;
    });
  }

  String get _summary => switch (_source) {
        CookieFile f => '${f.count} cookie${f.count == 1 ? '' : 's'} for '
            '${f.sites.length <= 3 ? f.sites.join(', ') : '${f.sites.length} sites'}',
        CookieBrowser b => 'From ${b.browser}${b.profile.isEmpty ? '' : ' (profile ${b.profile})'}',
        _ => 'No cookies: yt-dlp visits sites as a guest',
      };

  Future<void> _pickFile() async {
    final List<String> files;
    try {
      files = await AppScope.of(context).ports.folders.pickFiles(
        dialogTitle: 'Pick a cookies.txt or a JSON cookie export',
        extensions: const ['txt', 'json'],
      );
    } catch (_) {
      _reload('file dialog unavailable — try again');
      return;
    }
    final path = files.firstOrNull;
    if (path != null) await _importFile(path);
  }

  Future<void> _importFile(String path) async {
    final List<NetscapeCookie> all;
    try {
      all = parseCookies(await File(path).readAsString());
    } on FormatException catch (e) {
      _reload("Can't read that file: ${e.message}");
      return;
    } on FileSystemException catch (e) {
      _reload("Can't read that file: ${e.message}");
      return;
    }
    if (!mounted) return;
    // Every site in the file: an export is "my logins", not a pick list.
    try {
      await widget.cookies.saveFile(all);
      _reload();
    } catch (e) {
      _reload('Could not keep the cookies: $e');
    }
  }

  Future<void> _pickBrowser() async {
    final current = _source;
    final picked = await showDialog<CookieBrowser>(
      context: context,
      builder: (_) => _CookieBrowserDialog(initial: current is CookieBrowser ? current : null),
    );
    if (picked == null) return;
    try {
      await widget.cookies.saveBrowser(picked.browser, picked.profile);
      _reload();
    } catch (e) {
      _reload('Could not save: $e');
    }
  }

  Future<void> _remove() async {
    try {
      await widget.cookies.remove();
      _reload();
    } catch (e) {
      _reload('Could not remove the cookies: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppScope.of(context).ports.shell.dropTarget(
      onEnter: () => setState(() => _dragging = true),
      onExit: () => setState(() => _dragging = false),
      onDrop: (paths, _) {
        setState(() => _dragging = false);
        final path = paths.firstOrNull;
        if (path != null) _importFile(path);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _dragging ? scheme.primary : scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cookie_outlined),
              title: const Text('Cookies'),
              subtitle: Text(_summary, key: const ValueKey('ytdlp-cookies-summary')),
            ),
            if (_error != null)
              Text(_error!, key: const ValueKey('ytdlp-cookies-error'), style: TextStyle(color: scheme.error)),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickBrowser,
                  icon: const Icon(Icons.public),
                  label: const Text('From a browser…'),
                ),
                OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('From a file…'),
                ),
                if (_source != null)
                  TextButton(
                    key: const ValueKey('ytdlp-cookies-remove'),
                    onPressed: _remove,
                    child: const Text('Remove cookies'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'For sites that refuse guests (Bilibili, YouTube asking to sign in). Drop a cookies.txt or a '
              'cookie-extension JSON export here, or pick one; all of it is kept, on this computer only. '
              'Cookies log yt-dlp in as you on those sites. Keep the file private; for YouTube consider a '
              'throwaway account (Google may flag accounts used with yt-dlp).',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _CookieBrowserDialog extends StatefulWidget {
  final CookieBrowser? initial;
  const _CookieBrowserDialog({this.initial});

  @override
  State<_CookieBrowserDialog> createState() => _CookieBrowserDialogState();
}

class _CookieBrowserDialogState extends State<_CookieBrowserDialog> {
  late var _browser = widget.initial?.browser ?? cookieBrowsers.first;
  late final _profile = TextEditingController(text: widget.initial?.profile ?? '');

  @override
  void dispose() {
    _profile.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cookies from a browser'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Browser')),
                AppSelect<String>(
                  value: _browser,
                  items: [for (final b in cookieBrowsers) (b, b)],
                  onChanged: (v) => setState(() => _browser = v),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _profile,
              decoration: const InputDecoration(labelText: 'Profile (optional)', hintText: 'the default profile'),
            ),
            const SizedBox(height: 12),
            Text(
              'yt-dlp reads them each time it opens a link (the browser may need to be closed on Windows).',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, CookieBrowser(_browser, _profile.text.trim())),
          child: const Text('Use'),
        ),
      ],
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

/// What pops up (chat pop-ups: [AppSettings.chatPopups]), what reaches
/// you while you sit out or the window is in the background
/// ([AppSettings.notifyPeople]), and what makes a sound.
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
              line('Joins, leaves, lost connections and video changes',
                  "Pop up bottom left for 5 s with the person's picture, above the player's controls"),
              line('Added to Up next', 'With the title, its picture and who added it'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Chat messages'),
                          Text('Pop up the same way; always in Chat & activity (Tab)', style: muted),
                        ],
                      ),
                    ),
                    SignalBuilder(
                      builder: (context) => AppSelect<ChatPopups>(
                        key: const ValueKey('chat-popups'),
                        value: AppSettings.instance.chatPopups.value,
                        onChanged: AppSettings.instance.setChatPopups,
                        items: [for (final m in ChatPopups.values) (m, m.label)],
                      ),
                    ),
                  ],
                ),
              ),
              line('Sat out or nudged by someone', 'Only on your end, with their picture'),
              line('Ready, seeks and pauses', 'Only in Chat & activity (Tab), never as a pop-up'),
              line('Watching alone', 'No pop-ups or sounds about the party: there is nobody else'),
              line('App notices', 'Shader changes, copies, errors, auto sit-out setting you away'),
            ],
          ),
        ),
        SettingsPanel(
          title: 'Sitting out and in the background',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              line('What still reaches you',
                  'While you sit out, only chat, nudges, "starting now" and Up next pop up. With the window '
                  'in the background or minimised they also go out as system notifications; a click brings '
                  'the window up (a chat one opens the chat)'),
              SignalBuilder(
                builder: (context) => SwitchListTile(
                  key: const ValueKey('notify-people'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Joins and leaves too'),
                  subtitle: Text('Who joins, leaves, loses connection or comes back', style: muted),
                  value: AppSettings.instance.notifyPeople.value,
                  onChanged: AppSettings.instance.setNotifyPeople,
                ),
              ),
            ],
          ),
        ),
        const SettingsPanel(title: 'Sounds', child: SoundSettings()),
      ],
    );
  }
}

/// Volume and the sound set, then every sound with a preview button, its
/// own set (or the overall one) and its own switch.
class SoundSettings extends StatelessWidget {
  const SoundSettings({super.key});

  void _preview(BuildContext context, SfxKind kind) =>
      unawaited(AppScope.of(context).sfx.preview(kind, readyIndex: 2));

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return SignalBuilder(builder: (context) {
      final volume = s.soundVolume.value;
      final off = s.soundsOff.value;
      final overall = s.soundPreset.value;
      final per = s.soundPresetFor.value;
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
                  onChangeEnd: (_) => _preview(context, SfxKind.ready),
                ),
              ),
              SizedBox(width: 44, child: Text('${(volume * 100).round()}%', textAlign: TextAlign.end)),
            ],
          ),
          Text('Soft cues for people and readiness; the video itself covers play, pause and the end. '
              'Letting go of the slider plays the ready sound.', style: muted),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: Text('Sound set')),
              AppSelect<String>(
                key: const ValueKey('sound-preset'),
                value: overall,
                onChanged: (v) {
                  s.setSoundPreset(v);
                  _preview(context, SfxKind.ready);
                },
                items: [
                  for (final MapEntry(key: p, value: (name, _)) in presetInfo.entries) (p.name, name),
                ],
              ),
            ],
          ),
          Text(presetInfo.entries.where((e) => e.key.name == overall).firstOrNull?.value.$2 ?? '', style: muted),
          const SizedBox(height: 8),
          for (final MapEntry(key: kind, value: (name, help)) in soundInfo.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    key: ValueKey('sound-play-${kind.name}'),
                    tooltip: 'Play',
                    onPressed: volume == 0 ? null : () => _preview(context, kind),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text(name), Text(help, style: muted)],
                    ),
                  ),
                  AppSelect<String?>(
                    key: ValueKey('sound-preset-${kind.name}'),
                    value: per[kind.name],
                    style: muted,
                    onChanged: (v) {
                      s.setSoundPresetFor(kind.name, v);
                      if (volume > 0) _preview(context, kind);
                    },
                    items: [
                      (null, 'Same as set'),
                      for (final MapEntry(key: p, value: (name, _)) in presetInfo.entries) (p.name, name),
                    ],
                  ),
                  // A nudge always plays (an explicit poke): no switch,
                  // its place kept so the rows line up.
                  Visibility.maintain(
                    visible: kind != SfxKind.nudge,
                    child: Switch(
                      key: ValueKey('sound-on-${kind.name}'),
                      value: !off.contains(kind.name),
                      onChanged: volume == 0 || kind == SfxKind.nudge ? null : (on) => s.setSoundOn(kind.name, on),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }
}
