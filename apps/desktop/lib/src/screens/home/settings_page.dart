import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../playback/playback_controller.dart';
import '../../shaders/shader_presets.dart';
import '../../state/settings.dart';
import '../../update/update_controller.dart';
import 'profile.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// In-session keys, as handled by the session screen's global key handler.
const sessionShortcuts = [
  ('Space', 'Toggle ready'),
  ('← / →', 'Seek back / forward 10 s'),
  ('Shift+→', 'Skip 1:30 (for everyone)'),
  ('PgUp / PgDn', 'Previous / next chapter'),
  ('F', 'Toggle fullscreen'),
  ('Tab', 'Open / close the people & chat panel'),
  ('Ctrl+R', 'Reload the video'),
  ('> or Shift+N', 'Put up the next Jellyfin episode'),
  ('< or Shift+P', 'Put up the previous Jellyfin episode'),
  ('Ctrl+1…6', 'Shaders: Anime4K mode A, B, C, A+A, B+B, C+A'),
  ('Ctrl+0', 'Shaders off'),
  ('Esc', 'Close panel or fullscreen, else ask to leave'),
];

class SettingsPage extends StatelessWidget {
  final UpdateController? updates;
  const SettingsPage({super.key, this.updates});

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      maxWidth: 680,
      children: [
        const PageTitle('Settings'),
        const _Section(title: 'Profile', child: ProfileEditor()),
        const _Section(
          title: 'Player',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_HwdecSetting(), SizedBox(height: 12), _MpvControlsSetting()],
          ),
        ),
        const _Section(title: 'Jellyfin', child: _AutoAdvanceSetting()),
        _Section(title: 'Updates', child: _UpdateSettings(controller: updates)),
        const _Section(title: 'Keyboard shortcuts', child: _ShortcutList()),
        const _Section(title: 'Video quality & shaders', child: _ShaderSettings()),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SectionLabel(title), child],
        ),
      ),
    );
  }
}

class _HwdecSetting extends StatefulWidget {
  const _HwdecSetting();

  @override
  State<_HwdecSetting> createState() => _HwdecSettingState();
}

class _HwdecSettingState extends State<_HwdecSetting> {
  final _s = AppSettings.instance;
  late final _custom = TextEditingController(text: _s.hwdecCustom.peek());

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final mode = _s.hwdecMode.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hardware decoding'),
          const SizedBox(height: 4),
          const Text(
            'Applies on the next join or Reload video (Ctrl+R). Turn it off if video '
            'shows glitches or a black picture.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          SegmentedButton<HwdecMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: HwdecMode.auto, label: Text('Auto')),
              ButtonSegment(value: HwdecMode.off, label: Text('Off')),
              ButtonSegment(value: HwdecMode.custom, label: Text('Custom')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => _s.setHwdecMode(s.first),
          ),
          if (mode == HwdecMode.custom)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: _custom,
                decoration: fieldDecoration('mpv hwdec value',
                    hint: 'e.g. vaapi, nvdec, d3d11va, auto-safe'),
                onChanged: _s.setHwdecCustom,
              ),
            ),
        ],
      );
    });
  }
}

class _ShaderSettings extends StatelessWidget {
  const _ShaderSettings();

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
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final quality = s.shaderQuality.value;
      final custom = s.customShaders.value;
      final mode = PlaybackController.lastRenderMode.value;
      const hint = TextStyle(fontSize: 12, color: Colors.grey);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Anime4K upscales and sharpens anime on your GPU, for you only. '
            'Mode A suits 1080p sources, B 720p, C 480p; A+A, B+B and C+A add '
            'a second pass. HQ is for strong GPUs (GTX 1080 and up), Fast for '
            'weaker ones. Costs GPU time every frame and only works with '
            'hardware video rendering. In the player: the ✨ button or '
            'Ctrl+1…6, Ctrl+0 for off; changes apply live and are saved here.',
            style: hint,
          ),
          if (mode == RenderMode.software || mode == RenderMode.softwareGl)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                mode == RenderMode.software
                    ? 'The last session used software rendering: shaders had no effect there.'
                    : 'The last session rendered OpenGL on the CPU: shaders will be slow.',
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Shaders'),
              const SizedBox(width: 16),
              DropdownButton<ShaderPreset>(
                value: preset,
                onChanged: (p) {
                  if (p != null) s.setShaderPreset(p);
                },
                items: [
                  for (final p in ShaderPreset.values)
                    DropdownMenuItem(value: p, child: Text(p.label)),
                ],
              ),
              const Spacer(),
              SegmentedButton<ShaderQuality>(
                showSelectedIcon: false,
                segments: [
                  for (final q in ShaderQuality.values)
                    ButtonSegment(value: q, label: Text(q.label)),
                ],
                selected: {quality},
                onSelectionChanged: (q) => s.setShaderQuality(q.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: Text('Custom shaders (run in this order)')),
              TextButton.icon(
                onPressed: _addFiles,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add .glsl files'),
              ),
            ],
          ),
          if (custom.isEmpty)
            const Text('None picked.', style: hint)
          else
            for (final (i, path) in custom.indexed)
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: path,
                      child: Text(path.split(RegExp(r'[/\\]')).last,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        s.setCustomShaders([...custom]..removeAt(i)),
                  ),
                ],
              ),
        ],
      );
    });
  }
}

class _UpdateSettings extends StatelessWidget {
  final UpdateController? controller;
  const _UpdateSettings({this.controller});

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
            contentPadding: EdgeInsets.zero,
            title: const Text('Check automatically on start'),
            value: s.autoCheckUpdates.value,
            onChanged: s.setAutoCheckUpdates,
          ),
        ),
      ],
    );
  }
}

class _MpvControlsSetting extends StatelessWidget {
  const _MpvControlsSetting();

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        key: const ValueKey('mpv-controls'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Experimental: mpv-style controls'),
        subtitle: const Text('Video controls modeled on mpv\'s uosc theme: a thick timeline with '
            'chapters and the cached range, flat buttons and menus. Applies right away.'),
        value: s.mpvControls.value,
        onChanged: s.setMpvControls,
      ),
    );
  }
}

class _AutoAdvanceSetting extends StatelessWidget {
  const _AutoAdvanceSetting();

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SwitchListTile(
        key: const ValueKey('auto-advance'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Play the next episode automatically'),
        subtitle: const Text('When an episode ends, a 10 s countdown puts up the next one; '
            'anyone can cancel it on their screen.'),
        value: s.autoAdvance.value,
        onChanged: s.setAutoAdvance,
      ),
    );
  }
}

class _ShortcutList extends StatelessWidget {
  const _ShortcutList();

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
