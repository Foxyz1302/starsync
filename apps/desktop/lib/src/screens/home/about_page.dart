import 'package:flutter/material.dart';

import '../../update/update_controller.dart';
import '../../widgets/copy_open.dart';
import 'settings_page.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Name, version, update state and the source link (Settings → About).
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
            ],
          ),
        );
  }
}
