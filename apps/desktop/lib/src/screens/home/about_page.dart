import 'package:flutter/material.dart';

import '../../platform/app_log.dart';
import '../../update/update_controller.dart';
import '../../widgets/copy_open.dart';
import 'settings_page.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Name, version, update state, the source link and the logs (Settings →
/// About).
class AboutPanel extends StatelessWidget {
  final UpdateController? updates;
  const AboutPanel({super.key, this.updates});

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
              SelectableText('Version ${displayVersion()}',
                  style: t.bodyMedium?.copyWith(color: Colors.grey)),
              const SizedBox(height: 4),
              UpdateStatusLine(controller: updates),
              const SizedBox(height: kGap),
              Row(
                children: [
                  Expanded(child: SelectableText(repoUrl, style: t.bodySmall)),
                  IconButton(
                    tooltip: ReuseText.copyLink,
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => copyToClipboard(repoUrl, done: 'Link copied'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => openLink(repoUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Source'),
                  ),
                ],
              ),
              const SizedBox(height: kGap),
              Text('Something went wrong? Copy diagnostics and send them to whoever helps you: '
                  'versions and the last hours of the log, passwords, tokens and cookies left out.',
                  style: t.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _copyDiagnostics,
                    icon: const Icon(Icons.bug_report_outlined, size: 18),
                    label: const Text('Copy diagnostics'),
                  ),
                  OutlinedButton.icon(
                    onPressed: appLogDir == null ? null : () => _openLogs(),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Open logs folder'),
                  ),
                ],
              ),
            ],
          ),
        );
  }

  static Future<void> _copyDiagnostics() async {
    final text = await diagnosticsText();
    final saved = await saveDiagnostics(text);
    await copyToClipboard(text,
        done: saved == null ? 'Diagnostics copied' : 'Diagnostics copied (also saved in the logs folder)');
  }

  static Future<void> _openLogs() async {
    final dir = appLogDir;
    if (dir == null) return;
    // The file manager opens a folder path the way a browser opens a link.
    if (!await openInBrowser(Uri.directory(dir).toString())) {
      await copyToClipboard(dir, done: "Couldn't open it — folder path copied");
    }
  }
}
