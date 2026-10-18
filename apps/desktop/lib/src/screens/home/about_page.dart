import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../platform/app_log.dart';
import '../../shell/mark_problem.dart';
import '../../app/app_graph.dart';
import '../../state/settings.dart';
import '../../update/update_controller.dart';
import '../../update/whats_new.dart';
import '../../widgets/whats_new_card.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/copy_open.dart';
import 'settings_page.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// The Minimal player skin's credit (README says the same).
const uoscCredit = 'Player timeline and controls inspired by uosc by tomasklaen, LGPL-2.1 '
    '(github.com/tomasklaen/uosc).';

/// Dev builds only ([devTools]): previews and experiments not decided
/// yet (DEVELOPMENT.md "Dev tools").
class DeveloperPanel extends StatelessWidget {
  final VoidCallback? onDanmakuPreview;
  const DeveloperPanel({super.key, this.onDanmakuPreview});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SettingsPanel(
      title: 'Developer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Test builds only: try what is not decided yet.', style: t.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const ValueKey('danmaku-preview'),
            onPressed: onDanmakuPreview,
            icon: const Icon(Icons.subtitles_outlined, size: 18),
            label: const Text('Danmaku preview'),
          ),
        ],
      ),
    );
  }
}

/// Name, version, update state, What's new in this version, the source
/// link and the logs (Settings → About).
class AboutPanel extends StatelessWidget {
  final UpdateController? updates;
  final WhatsNew? whatsNew;
  const AboutPanel({super.key, this.updates, this.whatsNew});

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
              // This version's notes, once kept (the install, a check).
              ValueListenableBuilder(
                valueListenable: (updates ?? AppScope.of(context).updates).latest,
                builder: (context, _, _) {
                  final notes = (whatsNew ?? AppScope.of(context).whatsNew).current;
                  if (notes == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('about-whats-new'),
                      onPressed: () => showWhatsNew(context, notes),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: Text("What's new in ${notes.version}"),
                    ),
                  );
                },
              ),
              const SizedBox(height: kGap),
              Row(
                children: [
                  Expanded(child: SelectableText(repoUrl, style: t.bodySmall)),
                  IconButton(
                    tooltip: ReuseText.copyLink,
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => copyToClipboard(context, repoUrl, done: 'Link copied'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => openLink(context, repoUrl),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Source'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(uoscCredit, key: const ValueKey('uosc-credit'), style: t.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: kGap),
              Text('Something went wrong? Copy diagnostics and send them to whoever helps you: '
                  'versions and the last hours of the log, passwords, tokens and cookies left out. '
                  'In a session it can add the server\'s session log, everyone\'s lines merged. '
                  'Mark a problem (Ctrl+Shift+B) when it happens so the spot is easy to find.',
                  style: t.bodySmall?.copyWith(color: Colors.grey)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Builder(
                    builder: (context) => FilledButton.tonalIcon(
                      key: const ValueKey('copy-diagnostics'),
                      onPressed: () => _copyDiagnostics(context),
                      icon: const Icon(Icons.bug_report_outlined, size: 18),
                      label: const Text('Copy diagnostics'),
                    ),
                  ),
                  const MarkProblemButton(outlined: true),
                  OutlinedButton.icon(
                    onPressed: appLogDir == null ? null : () => _openLogs(context),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Open logs folder'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SignalBuilder(
                builder: (context) => SwitchListTile(
                  key: const ValueKey('share-diagnostics'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Share diagnostics with the server'),
                  subtitle: const Text('In a session, this app\'s log goes to the server\'s session log, '
                      'merged with everyone\'s, so a problem can be read afterwards. Never chat; '
                      'passwords and tokens left out. Off: only a problem you mark is sent.'),
                  value: AppSettings.instance.shareDiagnostics.value,
                  onChanged: AppSettings.instance.setShareDiagnostics,
                ),
              ),
            ],
          ),
        );
  }

  /// In a session it asks whether to add the server's session log.
  static Future<void> _copyDiagnostics(BuildContext context) async {
    var withServer = false;
    final graph = AppScope.of(context);
    if (graph.navigation.online.peek()) {
      final pick = await showAppMenu<bool>(context, items: const [
        AppMenuItem(value: false, label: "This app's log"),
        AppMenuItem(value: true, label: "This app's and the server's session log"),
      ]);
      if (pick == null) return;
      withServer = pick;
    }
    final text = await diagnosticsText(graph, sessionLog: withServer);
    final saved = await saveDiagnostics(text);
    if (!context.mounted) return;
    await copyToClipboard(context, text,
        done: saved == null ? 'Diagnostics copied' : 'Diagnostics copied (also saved in the logs folder)');
  }

  static Future<void> _openLogs(BuildContext context) async {
    final dir = appLogDir;
    if (dir == null) return;
    final folders = AppScope.of(context).ports.folders;
    if (!await folders.reveal(dir)) {
      if (!context.mounted) return;
      await copyToClipboard(context, dir, done: "Couldn't open it — folder path copied");
    }
  }
}
