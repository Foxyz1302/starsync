import 'package:flutter/material.dart';

import '../../update/update_controller.dart';
import 'connect_flow.dart';
import 'ui.dart';
import 'update_indicator.dart' show runUpdateCheck;

/// The Join button, swapped for a progress bar and Cancel while the
/// attempt runs.
class ConnectButton extends StatelessWidget {
  final ConnectFlow flow;
  final String label;
  final VoidCallback onSubmit;
  final bool expand;
  const ConnectButton({
    super.key,
    required this.flow,
    required this.label,
    required this.onSubmit,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    if (flow.busy) {
      return SizedBox(
        width: expand ? null : 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: Text('Connecting…', style: Theme.of(context).textTheme.bodySmall)),
                TextButton(onPressed: flow.cancel, child: const Text('Cancel')),
              ],
            ),
          ],
        ),
      );
    }
    final button = FilledButton(onPressed: onSubmit, child: Text(label));
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// The last error or notice, or nothing. A version gate that says this
/// app is the older one offers the update ([updates], default the app's
/// [UpdateController]).
class ConnectFeedback extends StatelessWidget {
  final ConnectFlow flow;
  final UpdateController? updates;
  const ConnectFeedback({super.key, required this.flow, this.updates});

  @override
  Widget build(BuildContext context) {
    final error = flow.error;
    final notice = flow.notice;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ErrorBox(title: error.title, message: error.message),
            if (error.offerUpdate)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('join-update'),
                  onPressed: () => runUpdateCheck(updates, true),
                  icon: const Icon(Icons.system_update_alt, size: 16),
                  label: const Text('Check for the update'),
                ),
              ),
          ],
        ),
      );
    }
    if (notice != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(notice, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
      );
    }
    return const SizedBox.shrink();
  }
}
