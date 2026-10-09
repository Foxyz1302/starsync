import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/settings.dart';
import '../../update/update_controller.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Session keys: Space and Tab anywhere in a server (`AppKeys`), the
/// rest by the session player's key handler (while it fills the window).
const sessionShortcuts = [
  ('Space', 'Toggle ready'),
  ('← / →', 'Seek back / forward 10 s'),
  ('↑ / ↓', 'Volume up / down (up to 150 %)'),
  ('Shift+→', 'Skip 1:30 (for everyone)'),
  ('PgUp / PgDn', 'Previous / next chapter'),
  ('F', 'Toggle fullscreen'),
  ('Tab', 'Open / close chat & activity'),
  ('Ctrl+R', 'Reload the video'),
  ('> or Shift+N', 'Put up the next Jellyfin episode'),
  ('< or Shift+P', 'Put up the previous Jellyfin episode'),
  ('Ctrl+1…6', 'Shaders: Anime4K mode A, B, C, A+A, B+B, C+A'),
  ('Ctrl+0', 'Shaders off'),
  ('Esc', 'Close the panel or fullscreen, else ask to leave'),
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

/// A tinted hint card at the top of a Settings page.
class SettingsHintCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const SettingsHintCard({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: kGap),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// The .glsl files of the "Custom shaders" preset, in mpv order.
class CustomShaderFiles extends StatelessWidget {
  const CustomShaderFiles({super.key});

  Future<void> _addFiles() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: 'Pick mpv GLSL shaders',
        type: FileType.custom,
        allowedExtensions: const ['glsl', 'hook'],
      );
    } catch (_) {
      return;
    }
    final s = AppSettings.instance;
    final current = s.customShaders.peek();
    final added = [
      for (final f in files)
        if (f.path case final p? when !current.contains(p)) p,
    ];
    if (added.isNotEmpty) s.setCustomShaders([...current, ...added]);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SignalBuilder(builder: (context) {
      final custom = s.customShaders.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Your own mpv shaders for the "Custom shaders" choice; they run in this order.',
                    style: muted),
              ),
              TextButton.icon(
                onPressed: _addFiles,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add .glsl files'),
              ),
            ],
          ),
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
      );
    });
  }
}

class UpdateSettings extends StatelessWidget {
  final UpdateController? controller;
  const UpdateSettings({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? UpdateController.instance;
    final s = AppSettings.instance;
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
        const SizedBox(height: 8),
        SignalBuilder(
          builder: (context) => SwitchListTile(
            key: const ValueKey('auto-check-updates'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Check for updates on start'),
            subtitle: const Text('Looks for a new version when the app opens; nothing installs without asking'),
            value: s.autoCheckUpdates.value,
            onChanged: s.setAutoCheckUpdates,
          ),
        ),
      ],
    );
  }
}

class AutoAdvanceSetting extends StatelessWidget {
  const AutoAdvanceSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        key: const ValueKey('auto-advance'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Play the next episode automatically'),
        subtitle: const Text('When a Jellyfin episode ends, a 10 s countdown puts up the next one; '
            'anyone can cancel it'),
        value: s.autoAdvance.value,
        onChanged: s.setAutoAdvance,
      ),
    );
  }
}

class HideReReleasesSetting extends StatelessWidget {
  const HideReReleasesSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        key: const ValueKey('hide-re-releases'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Hide re-releases in Latest'),
        subtitle: const Text('Skips episodes added more than 30 days after they aired '
            '(re-uploads, upgrades); also in each Latest row\'s ⋮ menu'),
        value: s.hideReReleases.value,
        onChanged: s.setHideReReleases,
      ),
    );
  }
}

class ShortcutList extends StatelessWidget {
  const ShortcutList({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('While watching:', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        for (final (key, what) in sessionShortcuts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(key,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                    ),
                  ),
                ),
                Expanded(child: Text(what)),
              ],
            ),
          ),
      ],
    );
  }
}
