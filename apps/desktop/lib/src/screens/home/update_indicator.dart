import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show isDevBuild;

import '../../update/update_controller.dart';
import '../../widgets/update_banner.dart';
import 'ui.dart';

/// The band across the top of the window while an update is up for
/// grabs: "Starsync 1.2.1 is ready", its notes, Update and restart and
/// Later (gone until the next check or start). The shell keeps it off
/// the full player while a video is on ([AppShell]).
class UpdateBar extends StatelessWidget {
  final UpdateController? controller;
  const UpdateBar({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? UpdateController.instance;
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: c.status,
      builder: (context, s, _) {
        final m = s.manifest;
        if (s.phase == UpdatePhase.idle || m == null) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final alert = m.isRequired || s.phase == UpdatePhase.failed;
        final fg = alert ? scheme.onErrorContainer : scheme.onPrimaryContainer;
        final current = c.currentVersion;
        // A release (not a test build) that is behind: say which it runs.
        final behind = isDevBuild(current) ? null : 'You are running $current';
        final String title;
        String detail;
        switch (s.phase) {
          case UpdatePhase.downloading:
            title = 'Downloading $appName ${m.version}… ${((s.progress ?? 0) * 100).round()}%';
            detail = '';
          case UpdatePhase.applying:
            title = 'Installing $appName ${m.version}…';
            detail = '';
          case UpdatePhase.restarting:
            title = 'Restarting into $appName ${m.version}…';
            detail = '';
          case UpdatePhase.failed:
            title = 'Update to $appName ${m.version} failed';
            detail = '${s.error}';
          case UpdatePhase.available || UpdatePhase.idle:
            if (!s.canInstall) {
              title = 'This copy of $appName is older than the latest release (${m.version})';
              detail = 'Download the new release and replace this folder by hand';
            } else if (m.isRequired) {
              title = '$appName ${m.version} is required to join servers on it';
              detail = m.notes;
            } else {
              title = '$appName ${m.version} is ready';
              detail = m.notes;
            }
            detail = [?behind, detail].where((t) => t.isNotEmpty).join(' · ');
        }
        final busy = s.phase == UpdatePhase.downloading ||
            s.phase == UpdatePhase.applying ||
            s.phase == UpdatePhase.restarting;
        return Material(
          key: const ValueKey('update-bar'),
          color: alert ? scheme.errorContainer : scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fg,
                      value: s.phase == UpdatePhase.downloading ? s.progress : null,
                    ),
                  )
                else
                  Icon(Icons.system_update_alt, size: 20, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                      if (detail.isNotEmpty)
                        Tooltip(
                          message: detail,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12)),
                        ),
                    ],
                  ),
                ),
                if (!busy) ...[
                  const SizedBox(width: 12),
                  if (!m.isRequired)
                    TextButton(
                      key: const ValueKey('update-later'),
                      style: TextButton.styleFrom(foregroundColor: fg),
                      onPressed: c.dismiss,
                      child: const Text('Later'),
                    ),
                  if (s.canInstall) ...[
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const ValueKey('update-install'),
                      onPressed: c.install,
                      child: Text(s.phase == UpdatePhase.failed ? 'Retry' : 'Update and restart'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The existing update card in a dialog; closes itself when the card
/// would render nothing (e.g. "Later").
Future<void> showUpdateDialog(BuildContext context, {UpdateController? controller}) {
  final c = controller ?? UpdateController.instance;
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      child: SizedBox(
        width: 420,
        child: ValueListenableBuilder<UpdateStatus>(
          valueListenable: c.status,
          builder: (context, s, _) {
            if (s.phase == UpdatePhase.idle || s.manifest == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).maybePop();
              });
            }
            return Padding(
              padding: const EdgeInsets.all(8),
              child: UpdateBanner(controller: c),
            );
          },
        ),
      ),
    ),
  );
}

/// How often a running app looks again (auto-check on).
const updateCheckEvery = Duration(hours: 4);

enum UpdateCheck { notRun, checking, done }

/// Progress of this run's update check, for Settings/About wording.
final updateCheck = ValueNotifier(UpdateCheck.notRun);

/// [force] re-checks even if this process already checked ("Check now").
Future<void> runUpdateCheck([UpdateController? controller, bool force = false]) async {
  final c = controller ?? UpdateController.instance;
  updateCheck.value = UpdateCheck.checking;
  try {
    await (force ? c.checkNow() : c.checkOnce());
  } finally {
    updateCheck.value = UpdateCheck.done;
  }
}

/// One-line update state: "Up to date", "Update v1.2 available", ...
class UpdateStatusLine extends StatelessWidget {
  final UpdateController? controller;
  const UpdateStatusLine({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? UpdateController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([c.status, c.lastCheck, updateCheck]),
      builder: (context, _) {
        final s = c.status.value;
        final m = s.manifest;
        final String text;
        if (c.skipDevBuilds && c.currentVersion.endsWith('-dev')) {
          text = 'Dev build — update checks are off';
        } else if (s.phase != UpdatePhase.idle && m != null) {
          text = s.phase == UpdatePhase.failed
              ? 'Update to v${m.version} failed'
              : 'Update v${m.version} available';
        } else {
          text = switch (updateCheck.value) {
            UpdateCheck.notRun => 'Not checked yet',
            UpdateCheck.checking => 'Checking…',
            UpdateCheck.done => c.lastCheck.value ?? 'Not checked yet',
          };
        }
        return Text(text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.grey));
      },
    );
  }
}
