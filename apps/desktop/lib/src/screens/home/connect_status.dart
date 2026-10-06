import 'package:flutter/material.dart';

import '../../state/session_state.dart';
import 'connect_flow.dart';
import 'ui.dart';

/// The submit button for one [ConnectMode], swapped for a progress bar and
/// Cancel while that attempt runs. Disabled while the other mode is busy.
class ConnectButton extends StatelessWidget {
  final ConnectFlow flow;
  final ConnectMode mode;
  final String label;
  final VoidCallback onSubmit;
  final bool expand;
  const ConnectButton({
    super.key,
    required this.flow,
    required this.mode,
    required this.label,
    required this.onSubmit,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final busyHere = flow.busy == mode;
    if (busyHere) {
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
                Expanded(
                  child: Text(mode == ConnectMode.host ? 'Starting server…' : 'Connecting…',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                TextButton(onPressed: flow.cancel, child: const Text('Cancel')),
              ],
            ),
          ],
        ),
      );
    }
    final button = FilledButton(
      onPressed: flow.busy != null ? null : onSubmit,
      child: Text(label),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Last error or notice for [mode], or nothing.
class ConnectFeedback extends StatelessWidget {
  final ConnectFlow flow;
  final ConnectMode mode;
  const ConnectFeedback({super.key, required this.flow, required this.mode});

  @override
  Widget build(BuildContext context) {
    final error = flow.errors[mode];
    final notice = flow.notices[mode];
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: ErrorBox(title: error.title, message: error.message),
      );
    }
    if (notice != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(notice,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
      );
    }
    return const SizedBox.shrink();
  }
}
