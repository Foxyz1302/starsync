import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../update/update_controller.dart';

// "Update available" card (Settings → Show update dialog). Kicks off the one
// background check on first build; renders nothing until there is an
// update to offer. Never shown over playback.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, this.controller});

  final UpdateController? controller;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  UpdateController get _c => widget.controller ?? UpdateController.instance;

  @override
  void initState() {
    super.initState();
    _c.checkOnce();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: _c.status,
      builder: (context, s, _) {
        final m = s.manifest;
        if (s.phase == UpdatePhase.idle || m == null) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final required = m.isRequired;
        final title = required
            ? 'Required update: v${m.version}'
            : 'Update available: v${m.version}';
        final lines = <Widget>[
          Text(title, style: theme.textTheme.titleSmall),
          if (required)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Servers on the new version use a newer protocol — '
                'this version cannot join them.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (m.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(m.notes,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          const SizedBox(height: 8),
          ..._body(s),
        ];
        return Card(
          color: required ? theme.colorScheme.errorContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: lines,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _body(UpdateStatus s) {
    switch (s.phase) {
      case UpdatePhase.downloading:
        return [
          LinearProgressIndicator(value: s.progress),
          const SizedBox(height: 4),
          Text('Downloading… ${((s.progress ?? 0) * 100).round()}%',
              style: const TextStyle(fontSize: 12)),
        ];
      case UpdatePhase.applying:
        return const [
          LinearProgressIndicator(),
          SizedBox(height: 4),
          Text('Installing…', style: TextStyle(fontSize: 12)),
        ];
      case UpdatePhase.restarting:
        return const [Text('Restarting…', style: TextStyle(fontSize: 12))];
      case UpdatePhase.failed:
        return [
          Text('Update failed: ${s.error}',
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          _actions(retry: true, manifest: s.manifest!),
        ];
      case UpdatePhase.available:
        if (!s.canInstall) {
          return const [
            Text(
              'Not a packaged install — download the new release and '
              'replace this folder by hand.',
              style: TextStyle(fontSize: 12),
            ),
          ];
        }
        return [_actions(retry: false, manifest: s.manifest!)];
      case UpdatePhase.idle:
        return const [];
    }
  }

  Widget _actions({required bool retry, required UpdateManifest manifest}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (!manifest.isRequired)
          TextButton(onPressed: _c.dismiss, child: const Text('Later')),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _c.install,
          child: Text(retry ? 'Retry' : 'Update and restart'),
        ),
      ],
    );
  }
}
