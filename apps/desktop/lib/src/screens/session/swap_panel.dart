import 'package:flutter/material.dart';

import '../../jellyfin/accounts.dart';
import '../../jellyfin/browse_scope.dart' show BrowseStart;
import '../home/media_picker.dart';

/// The Library tab's body: the [MediaPicker] (Jellyfin browser, Link,
/// File) and a button that puts the pick up for everyone. A file streams from this computer: the host's app
/// serves it, anyone else's goes through the server's relay. [onSwap]
/// returns an error text, or null when sent.
class SwapPanel extends StatefulWidget {
  final MediaPickerController controller;
  final JellyfinAccounts accounts;
  final bool isHost;
  final BrowseStart? jellyfinStart;
  final Future<String?> Function(PickedMedia media) onSwap;

  /// After a pick went up.
  final VoidCallback? onDone;
  final VoidCallback? onOpenIntegrations;

  /// Set when nothing can go up (offline): shown instead of the pick, and
  /// the button is off.
  final String? disabledHint;
  const SwapPanel({
    super.key,
    required this.controller,
    required this.accounts,
    required this.isHost,
    required this.onSwap,
    this.onDone,
    this.jellyfinStart,
    this.onOpenIntegrations,
    this.disabledHint,
  });

  @override
  State<SwapPanel> createState() => _SwapPanelState();
}

class _SwapPanelState extends State<SwapPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _swap() async {
    final media = widget.controller.selection;
    if (media == null || _busy || widget.disabledHint != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSwap(media);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hint = widget.disabledHint;
    return Padding(
      key: const ValueKey('swap-panel'),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: MediaPicker(
                controller: widget.controller,
                jellyfin: widget.accounts,
                enabled: !_busy,
                linkRelayChoice: true,
                fileHelp: widget.isHost
                    ? 'Friends stream it from your computer.'
                    : 'Streams from your computer through the server. Keep the app open while it plays.',
                jellyfinStart: widget.jellyfinStart,
                onOpenIntegrations: widget.onOpenIntegrations,
                onSubmit: _swap,
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final sel = widget.controller.selection;
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ??
                          hint ??
                          (sel == null
                              ? 'Pick something to watch'
                              : 'Put up: ${sel.label}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(
                        color: _error != null
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    key: const ValueKey('swap-go'),
                    onPressed: sel == null || _busy || hint != null
                        ? null
                        : _swap,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz),
                    label: const Text('Put it up for everyone'),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
