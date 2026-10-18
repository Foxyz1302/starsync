import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show UpdateChannel, isDevBuild;

import '../../app/app_graph.dart';
import '../../state/settings.dart';
import '../../update/update_controller.dart';
import '../../widgets/setting_rows.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// The keys, by where they work (Settings → Help & about → Keyboard
/// shortcuts). The player's: Space and Tab anywhere in a server
/// (`AppKeys`), the rest by the session player's key handler while it
/// fills the window.
const playerShortcuts = [
  ('Space', 'Toggle ready (anywhere in a server)'),
  ('← / →', 'Seek back / forward 10 s'),
  ('↑ / ↓, wheel', 'Volume up / down (up to 150 %)'),
  ('M', 'Mute / unmute'),
  ('Shift+→', 'Skip 1:30 (for everyone)'),
  ('PgUp / PgDn', 'Previous / next chapter'),
  ('F', 'Toggle fullscreen'),
  ('Enter', 'Quick chat box (Enter sends, Esc closes)'),
  ('Tab', 'Open / close chat & activity (anywhere in a server)'),
  ('Ctrl+R', 'Reload the video'),
  ('> or Shift+N', 'Play what is next: Up next, else the next episode'),
  ('< or Shift+P', 'Put up the previous episode'),
  ('Ctrl+1…6', 'Shaders: Anime4K mode A, B, C, A+A, B+B, C+A'),
  ('Ctrl+0', 'Shaders off'),
  ('Esc', 'Close a menu, the player settings panel, the chat or fullscreen, shrink the player, then ask to leave'),
];

/// Keys that work all over the app.
const anywhereShortcuts = [
  ('Ctrl+,', 'Settings'),
  ('Ctrl+V', 'Open a pasted link, file or invite (outside a text field)'),
  ('Ctrl+Shift+B', 'Mark a problem in the session log'),
];

/// The Jellyfin library's keys.
const libraryShortcuts = [
  ('/ or Ctrl+F', 'Search'),
  ('Esc', 'Clear the search, then go back'),
  ('Backspace, Alt+←', 'Back'),
];

/// One titled card of the Settings tab (rounded Material, so list tiles
/// paint their ripple on it).
class SettingsPanel extends StatelessWidget {
  final String title;
  final Widget child;
  const SettingsPanel({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// The .glsl files of the "Custom shaders" choice, in mpv order.
class CustomShaderFiles extends StatelessWidget {
  const CustomShaderFiles({super.key});

  Future<void> _addFiles(BuildContext context, AppSettings s) async {
    final folders = AppScope.of(context).ports.folders;
    final List<String> files;
    try {
      files = await folders.pickFiles(
        dialogTitle: 'Pick mpv GLSL shaders',
        extensions: const ['glsl', 'hook'],
      );
    } catch (_) {
      return;
    }
    final current = s.customShaders.peek();
    final added = [
      for (final p in files)
        if (!current.contains(p)) p,
    ];
    if (added.isNotEmpty) s.setCustomShaders([...current, ...added]);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SignalBuilder(builder: (context) {
      final custom = s.customShaders.value;
      return SettingRow(
        label: 'Custom shader files',
        help: 'Your own mpv shaders for the "Custom shaders" choice; they run in this order',
        control: TextButton.icon(
          key: const ValueKey('add-shaders'),
          onPressed: () => _addFiles(context, s),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add .glsl files'),
        ),
        below: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (custom.isEmpty)
              Text('None picked.', style: muted)
            else
              for (final (i, path) in custom.indexed)
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: path,
                        child: Text(path.split(RegExp(r'[/\\]')).last, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => s.setCustomShaders([...custom]..removeAt(i)),
                    ),
                  ],
                ),
          ],
        ),
      );
    });
  }
}

/// Where updates stand, Check now and Show update; the channel under
/// More. Checks run by themselves (at start and every few hours); nothing
/// installs without asking.
class UpdateSettings extends StatelessWidget {
  final UpdateController? controller;
  const UpdateSettings({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? AppScope.of(context).updates;
    final s = AppScope.of(context).coordinator.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: UpdateStatusLine(controller: c)),
            ValueListenableBuilder(
              valueListenable: c.status,
              builder: (context, st, _) {
                if (st.phase == UpdatePhase.idle || st.manifest == null) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.tonal(
                    onPressed: () => showUpdateDialog(context, controller: c),
                    child: const Text('Show update'),
                  ),
                );
              },
            ),
            ValueListenableBuilder(
              valueListenable: updateCheck,
              builder: (context, check, _) => OutlinedButton(
                onPressed: check == UpdateCheck.checking ? null : () => runUpdateCheck(c, true),
                child: const Text('Check now'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Checked when the app opens and every few hours; nothing installs without asking.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
        SettingFold(children: [UpdateChannelSetting(controller: c, settings: s)]),
      ],
    );
  }
}

/// Stable or Dev (test builds). Leaving Dev in a test build asks whether
/// to go back to the latest release now when that one is older.
class UpdateChannelSetting extends StatelessWidget {
  final UpdateController controller;
  final AppSettings settings;
  const UpdateChannelSetting({super.key, required this.controller, required this.settings});

  Future<void> _choose(BuildContext context, UpdateChannel ch) async {
    final s = settings;
    if (ch == s.updateChannel.peek()) return;
    s.setUpdateChannel(ch);
    if (ch == UpdateChannel.stable && isDevBuild(controller.currentVersion)) {
      final m = await controller.stableToGoBackTo();
      if (m != null && context.mounted) {
        final back = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Go back to stable ${m.version}?'),
            content: Text('This is test build ${controller.currentVersion}, newer than the latest release. '
                'Going back installs ${m.version} and restarts the app. Or stay on this build: '
                'the next release newer than it is offered as usual.'),
            actions: [
              TextButton(
                key: const ValueKey('stay-on-test-build'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Stay on this build'),
              ),
              TextButton(
                key: const ValueKey('go-back-to-stable'),
                onPressed: () => Navigator.pop(context, true),
                child: Text('Go back to ${m.version}'),
              ),
            ],
          ),
        );
        if (back == true) {
          await controller.goBackTo(m);
          return;
        }
      }
    }
    await runUpdateCheck(controller, true);
  }

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return SignalBuilder(builder: (context) {
      final ch = s.updateChannel.value;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Update channel'),
        subtitle: Text('On ${ch == UpdateChannel.dev ? 'Dev' : 'Stable'}, running ${controller.currentVersion}. '
            '${ch == UpdateChannel.dev ? 'Test builds and releases, whichever is newer; stays on Dev after a release' : 'Releases only'}'),
        trailing: SegmentedButton<UpdateChannel>(
          key: const ValueKey('update-channel'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: UpdateChannel.stable, label: Text('Stable')),
            ButtonSegment(value: UpdateChannel.dev, label: Text('Dev')),
          ],
          selected: {ch},
          onSelectionChanged: (sel) => _choose(context, sel.first),
        ),
      );
    });
  }
}


/// Settings → Player → Playback.
class AutoAdvanceSetting extends StatelessWidget {
  const AutoAdvanceSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingSwitch(
        switchKey: const ValueKey('auto-advance'),
        label: 'Play the next episode automatically',
        help: 'When you put up an episode (Jellyfin, or a file of a show in Files), the next one continues it '
            'after a 10 s countdown everyone sees; anyone can cancel it',
        value: s.autoAdvance.value,
        onChanged: s.setAutoAdvance,
      ),
    );
  }
}

/// Every key, by where it works: the player's first, the rest folded.
class ShortcutList extends StatelessWidget {
  const ShortcutList({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12);
    Widget row((String, String) k) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 152,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(k.$1, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  ),
                ),
              ),
              Expanded(child: Text(k.$2)),
            ],
          ),
        );
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text(text, style: muted),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('While the player fills the window'),
        for (final k in playerShortcuts) row(k),
        SettingFold(
          title: 'Anywhere, and in the library',
          children: [
            heading('Anywhere'),
            for (final k in anywhereShortcuts) row(k),
            heading('Jellyfin library'),
            for (final k in libraryShortcuts) row(k),
          ],
        ),
      ],
    );
  }
}
