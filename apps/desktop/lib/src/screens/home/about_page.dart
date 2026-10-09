import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart';

import '../../update/update_controller.dart';
import 'settings_page.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Opens [url] in the default browser (no url_launcher dependency).
Future<bool> openInBrowser(String url) async {
  try {
    final ProcessResult r;
    if (Platform.isWindows) {
      r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      r = await Process.run('open', [url]);
    } else {
      r = await Process.run('xdg-open', [url]);
    }
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Name, version, update state and the source link (Settings → About).
class AboutPanel extends StatelessWidget {
  final UpdateController? updates;
  const AboutPanel({super.key, this.updates});

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await openInBrowser(repoUrl)) return;
    await Clipboard.setData(const ClipboardData(text: repoUrl));
    messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open a browser — link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SettingsPanel(
          title: 'About',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(appName, style: t.titleLarge),
              const SizedBox(height: 4),
              SelectableText('Version $appVersion',
                  style: t.bodyMedium?.copyWith(color: Colors.grey)),
              const SizedBox(height: 4),
              UpdateStatusLine(controller: updates),
              const SizedBox(height: kGap),
              Row(
                children: [
                  Expanded(child: SelectableText(repoUrl, style: t.bodySmall)),
                  IconButton(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        Clipboard.setData(const ClipboardData(text: repoUrl)),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _open(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Source'),
                  ),
                ],
              ),
            ],
          ),
        );
  }
}
