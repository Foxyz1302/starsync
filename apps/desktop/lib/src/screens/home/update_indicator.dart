import 'package:flutter/material.dart';

import '../../update/update_controller.dart';
import '../../widgets/update_banner.dart';
import 'ui.dart';

/// Compact "Update vX" pill for the party strip; hidden until there is
/// something to install. Click opens the full [UpdateBanner].
class UpdateIndicator extends StatelessWidget {
  final UpdateController? controller;
  const UpdateIndicator({super.key, this.controller});

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
        final busy = s.phase == UpdatePhase.downloading ||
            s.phase == UpdatePhase.applying ||
            s.phase == UpdatePhase.restarting;
        final label = switch (s.phase) {
          UpdatePhase.downloading =>
            'Updating ${((s.progress ?? 0) * 100).round()}%',
          UpdatePhase.applying => 'Installing…',
          UpdatePhase.restarting => 'Restarting…',
          UpdatePhase.failed => 'Update failed',
          _ => m.isRequired ? 'Required update' : 'Update v${m.version}',
        };
        return Tooltip(
          message: 'Show update',
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: m.isRequired || s.phase == UpdatePhase.failed
                  ? scheme.errorContainer
                  : null,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => showUpdateDialog(context, controller: c),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.system_update_alt, size: 18),
            label: Text(label),
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
