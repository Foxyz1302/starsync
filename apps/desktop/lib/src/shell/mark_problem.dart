import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart' show RelayConstants;

import '../session/app_events.dart' show ProblemMarked;
import '../app/app_graph.dart';
import '../widgets/app_menu.dart' show AppGlass;
import 'motion.dart';

// "Mark a problem" (Ctrl+Shift+B, the player's ⋯, Settings → About): a
// marker line in the server's session log at this moment, with an
// optional short note, so whoever reads the log finds the spot.

/// The key that opens it.
const markProblemKey = SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true);

/// Asks for the note, then marks; the toast says where it went.
Future<void> showMarkProblem(BuildContext context) async {
  final note = await showPopover<String>(context, at: Alignment.center, child: const MarkProblemCard());
  if (note == null || !context.mounted) return;
  final coord = AppScope.of(context).coordinator;
  final inSession = await coord.markProblem(note);
  coord.notify(ProblemMarked(inSession: inSession));
}

/// The small card: a one-line note and Mark. Pops with the note (maybe
/// empty), or nothing on Cancel / Esc.
class MarkProblemCard extends StatefulWidget {
  const MarkProblemCard({super.key});

  @override
  State<MarkProblemCard> createState() => _MarkProblemCardState();
}

class _MarkProblemCardState extends State<MarkProblemCard> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _mark() => Navigator.of(context).pop(_note.text.trim());

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AppGlass(
      key: const ValueKey('mark-problem-card'),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Mark a problem', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 4),
              Text("Puts a marker in the server's session log right now, so whoever reads it finds the moment.",
                  style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('mark-problem-note'),
                controller: _note,
                autofocus: true,
                maxLength: RelayConstants.maxProblemNoteLength,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'What happened? (optional)',
                  counterText: '',
                ),
                onSubmitted: (_) => _mark(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const ValueKey('mark-problem-go'),
                    onPressed: _mark,
                    child: const Text('Mark'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Mark a problem" as a quiet row button (the player panel, Settings → About).
class MarkProblemButton extends StatelessWidget {
  final bool outlined;
  const MarkProblemButton({super.key, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.flag_outlined, size: 18);
    const label = Text('Mark a problem');
    void open() => showMarkProblem(context);
    return Tooltip(
      message: 'Ctrl+Shift+B',
      child: outlined
          ? OutlinedButton.icon(key: const ValueKey('mark-problem'), onPressed: open, icon: icon, label: label)
          : TextButton.icon(key: const ValueKey('mark-problem'), onPressed: open, icon: icon, label: label),
    );
  }
}
