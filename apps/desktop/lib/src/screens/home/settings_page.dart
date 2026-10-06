import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/settings.dart';
import '../../update/update_controller.dart';
import 'profile.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// In-session keys, as handled by the session screen's global key handler.
const sessionShortcuts = [
  ('Space', 'Toggle ready'),
  ('← / →', 'Seek back / forward 10 s'),
  ('F', 'Toggle fullscreen'),
  ('Tab', 'Open / close the people & chat panel'),
  ('Ctrl+R', 'Reload the video'),
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
        const _Section(title: 'Player', child: _HwdecSetting()),
        _Section(title: 'Updates', child: _UpdateSettings(controller: updates)),
        const _Section(title: 'Keyboard shortcuts', child: _ShortcutList()),
        const _Section(
          title: 'Video quality & shaders',
          enabled: false,
          trailing: _SoonBadge(),
          child: Text('Upscaling and shader presets for mpv.',
              style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final bool enabled;
  final Widget? trailing;
  const _Section(
      {required this.title, required this.child, this.enabled = true, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap),
      child: Panel(
        enabled: enabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SectionLabel(title, trailing: trailing), child],
        ),
      ),
    );
  }
}

class _SoonBadge extends StatelessWidget {
  const _SoonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('Coming soon', style: TextStyle(fontSize: 12)),
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
