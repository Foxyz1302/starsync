import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart'
    show CookieBrowser, CookieFile, NetscapeCookie, YtDlp, YtDlpCookies, cookieBrowsers, parseCookies;

import '../controls/model/controls_prefs.dart' show OptionalControl;
import '../controls/player_settings.dart';
import '../danmaku/danmaku_settings.dart' show DanmakuLookSettings;
import '../jellyfin/accounts.dart';
import '../jellyfin/accounts_panel.dart';
import '../schedule/animeflow.dart';
import '../screens/home/about_page.dart';
import '../screens/home/settings_page.dart';
import '../screens/home/ui.dart' show appName, devTools, displayVersion;
import '../session/identity.dart' show Profile;
import '../sfx/sfx.dart';
import '../sfx/sound_bank.dart';
import '../app/app_graph.dart';
import '../update/update_controller.dart';
import '../widgets/app_menu.dart';
import 'avatar.dart';
import 'motion.dart';
import 'notice_settings.dart';
import 'profile_card.dart' show ProfileColors, ProfilePicture;

/// The Settings tab's pages, in nav order. Ctrl+, opens the one last
/// shown, Player at first.
enum SettingsSection {
  player(Icons.play_circle_outline, 'Player'),
  party(Icons.hub_outlined, 'Party'),
  notifications(Icons.notifications_none, 'Notifications & sounds'),
  library(Icons.video_library_outlined, 'Library & accounts'),
  updates(Icons.system_update_alt, 'Updates'),
  help(Icons.help_outline, 'Help & about');

  final IconData icon;
  final String label;
  const SettingsSection(this.icon, this.label);
}

/// App-wide settings under a left nav (chips on top when narrow), each
/// page a column of cards, the common rows first and the rest under
/// "More"; the shell owns [section] so the profile card and the player
/// panel can open a page.
class SettingsTab extends StatelessWidget {
  final SettingsSection section;
  final ValueChanged<SettingsSection> onSection;
  final UpdateController? updates;
  /// Defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  /// AnimeFlow's `/me` for the Library & accounts page (tests pass a fake).
  final Future<AnimeFlowMe> Function()? animeFlowMe;
  /// The AnimeFlow address the card is about; null: the app's
  /// (`AppSettings.animeFlowAddress`). Empty: no card.
  final ReadonlySignal<String>? animeFlowAddress;
  /// Dev builds: Help & about → Developer → Danmaku preview.
  final VoidCallback? onDanmakuPreview;
  const SettingsTab({
    super.key,
    required this.section,
    required this.onSection,
    this.updates,
    this.jellyfin,
    this.animeFlowMe,
    this.animeFlowAddress,
    this.onDanmakuPreview,
  });

  List<Widget> _page(BuildContext context) {
    switch (section) {
      case SettingsSection.player:
        final muted = Theme.of(context).colorScheme.onSurfaceVariant;
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('Also in the player: ⚙ in the control bar opens these while you watch.',
                style: TextStyle(color: muted, fontSize: 12)),
          ),
          const SettingsPanel(key: ValueKey('player-sound'), title: 'Sound', child: VideoVolumeSetting()),
          const SettingsPanel(
            title: 'Subtitles',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [SubScaleSetting(), LiftSubtitlesSetting()],
            ),
          ),
          const SettingsPanel(
            title: 'Picture',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ShaderPresetSetting(),
                SettingFold(children: [CustomShaderFiles(), ScreenResSetting(), HwdecSetting()]),
              ],
            ),
          ),
          SettingsPanel(
            title: 'Controls',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PlayerDesignSetting(),
                const ControlsSizeSetting(),
                const ProgressLineSetting(),
                SettingFold(children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Buttons in the bar (hidden ones are in the top bar\'s ⋯)',
                        style: TextStyle(color: muted, fontSize: 12)),
                  ),
                  for (final c in OptionalControl.values) BarButtonSetting(control: c),
                ]),
              ],
            ),
          ),
          const SettingsPanel(title: 'Playback', child: AutoAdvanceSetting()),
        ];
      case SettingsSection.party:
        return [
          const YouPanel(),
          const YourServerPanel(),
          const RecentServersPanel(),
        ];
      case SettingsSection.notifications:
        return const [NotificationsInfo()];
      case SettingsSection.library:
        final accounts = jellyfin ?? JellyfinAccounts.instance;
        final flowAt = animeFlowAddress ?? AppScope.of(context).coordinator.settings.animeFlowAddress;
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: JellyfinAccountsPanel(accounts: accounts),
          ),
          // Only once a server offered AnimeFlow.
          SignalBuilder(builder: (context) {
            final at = flowAt.value;
            if (at.isEmpty) return const SizedBox.shrink();
            return AnimeFlowCard(
              key: ValueKey(at),
              address: at,
              me: animeFlowMe ??
                  () async {
                    final client = AnimeFlowClient.fromAccounts(accounts, baseUrl: at);
                    try {
                      return await client.me();
                    } finally {
                      client.close();
                    }
                  },
            );
          }),
          const SettingsPanel(key: ValueKey('web-links'), title: 'Web links', child: YtDlpSettings()),
        ];
      case SettingsSection.updates:
        return [SettingsPanel(title: 'Updates', child: UpdateSettings(controller: updates))];
      case SettingsSection.help:
        return [
          const SettingsPanel(title: 'Something wrong?', child: DiagnosticsPanel()),
          const SettingsPanel(title: 'Keyboard shortcuts', child: ShortcutList()),
          AboutPanel(updates: updates),
          if (devTools) DeveloperPanel(onDanmakuPreview: onDanmakuPreview),
        ];
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
                width: 280,
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

/// Party → You: your picture, name and colour, edited here as on the
/// profile card (your avatar in the strip), with the same widgets.
class YouPanel extends StatefulWidget {
  const YouPanel({super.key});

  @override
  State<YouPanel> createState() => _YouPanelState();
}

class _YouPanelState extends State<YouPanel> {
  late final Profile _p = AppScope.of(context).profile;
  late final _name = TextEditingController(text: _p.name.peek());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return SettingsPanel(
      key: const ValueKey('party-you'),
      title: 'You',
      child: SignalBuilder(builder: (context) {
        final png = _p.picture.value;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProfilePicture(profile: _p, info: selfAvatarInfo()),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('party-name'),
                    controller: _name,
                    maxLength: 32,
                    decoration: const InputDecoration(isDense: true, counterText: '', labelText: 'Name'),
                    onChanged: _p.setName,
                  ),
                  const SizedBox(height: 14),
                  ProfileColors(profile: _p),
                  if (_p.error.value case final err?)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(err, style: TextStyle(color: scheme.error, fontSize: 12)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                              'Others see your name and picture; the colour is yours only. Click the picture to '
                              'change it.',
                              style: small),
                        ),
                        if (png != null)
                          TextButton(onPressed: () => _p.setPicture(null), child: const Text('Remove picture')),
                      ],
                    ),
                  ),
                  const SettingFold(children: [AvatarShapeSetting()]),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Party: your server's port and password, used when you
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

/// Party: the servers Join offers in one click.
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
            Text('Join offers these in one click; forget the ones you no longer use',
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
                  tooltip: 'Forget',
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

/// AnimeFlow (the Schedule tab's source) at [address]: connected as
/// whom, with which rights, or why not.
class AnimeFlowCard extends StatefulWidget {
  final String address;
  final Future<AnimeFlowMe> Function() me;
  const AnimeFlowCard({super.key, required this.address, required this.me});

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
                title: Text(Uri.tryParse(widget.address)?.host ?? widget.address),
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
                'Offered by the last server you joined that has it; signs in with your Jellyfin account '
                'on the same domain.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Settings → Notifications & sounds: what shows over the video and
/// what makes a sound; the common rows first, the rest under More.
class NotificationsInfo extends StatelessWidget {
  const NotificationsInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).coordinator.settings;
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
          key: const ValueKey('over-the-video'),
          title: 'Over the video',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const NotifyStyleSetting(),
              const ChatPopupsSetting(),
              const NotifyPeopleSetting(),
              SettingFold(children: [
                Text('Danmaku look', style: Theme.of(context).textTheme.titleSmall),
                DanmakuLookSettings(settings: settings),
                const SizedBox(height: 8),
                Text('What pops up when', style: Theme.of(context).textTheme.titleSmall),
                line('Joins, leaves, lost connections and video changes',
                    "Bottom left for 5 s with the person's picture, above the player's controls (or flying "
                    'across the picture with Danmaku)'),
                line('Added to Up next', 'With the title, its picture and who added it'),
                line('Chat messages', 'As Chat pop-ups says; always in Chat & activity (Tab)'),
                line('Set out, waited for or nudged by someone', 'Only on your end, with their picture'),
                line('BRBs, seeks and pauses', 'Only in Chat & activity (Tab), never as a pop-up'),
                line('Watching alone', 'No pop-ups or sounds about the party: there is nobody else'),
                line('App notices', 'Shader changes, copies, errors, being set AFK'),
                line('Out or in the background',
                    'Only chat, nudges, "starting now" and Up next (and joins and leaves when switched on); with '
                    'the window in the background or minimised they go out as system notifications, and a click '
                    'brings the window up (a chat one opens the chat)'),
              ]),
            ],
          ),
        ),
        const SettingsPanel(title: 'Sounds', child: SoundSettings()),
      ],
    );
  }
}

/// App sounds and the sound set; under More every sound with a preview
/// button, its own set (or the overall one) and its own switch.
class SoundSettings extends StatelessWidget {
  const SoundSettings({super.key});

  void _preview(BuildContext context, SfxKind kind) =>
      unawaited(AppScope.of(context).sfx.preview(kind, readyIndex: 2));

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
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
          const AppSoundsSetting(),
          SettingRow(
            label: 'Sound set',
            help: presetInfo.entries.where((e) => e.key.name == overall).firstOrNull?.value.$2,
            control: AppSelect<String>(
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
          ),
          SettingFold(
            title: 'Each sound',
            children: [
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
                          onChanged:
                              volume == 0 || kind == SfxKind.nudge ? null : (on) => s.setSoundOn(kind.name, on),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      );
    });
  }
}

/// "Avatar shape": everyone's picture as a rounded square (the default) or
/// a circle, everywhere people show. Settings → Party → More only.
class AvatarShapeSetting extends StatelessWidget {
  const AvatarShapeSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Avatar shape',
        help: "How everyone's picture is cut, in the strip, the player and the cards",
        control: AppSelect<bool>(
          key: const ValueKey('avatar-shape'),
          value: s.avatarCircle.value,
          items: const [(false, 'Rounded square'), (true, 'Circle')],
          onChanged: s.setAvatarCircle,
        ),
      ),
    );
  }
}
