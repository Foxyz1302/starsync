import 'package:flutter/material.dart';

import '../../jellyfin/accounts.dart';
import '../../jellyfin/browse_scope.dart' show BrowseStart;
import '../home/media_picker.dart';

/// "Change video" in a session: the same [MediaPicker] as Home's Host tab
/// (Jellyfin browser, Link, File) and a button that puts the pick up for
/// everyone. File is offered to the host only (the file streams from the
/// host's disk). [onSwap] returns an error text, or null when sent.
class SwapPanel extends StatefulWidget {
  final MediaPickerController controller;
  final JellyfinAccounts accounts;
  final bool isHost;
  final BrowseStart? jellyfinStart;
  final Future<String?> Function(PickedMedia media) onSwap;
  final VoidCallback onClose;
  final VoidCallback? onOpenIntegrations;
  const SwapPanel({
    super.key,
    required this.controller,
    required this.accounts,
    required this.isHost,
    required this.onSwap,
    required this.onClose,
    this.jellyfinStart,
    this.onOpenIntegrations,
  });

  @override
  State<SwapPanel> createState() => _SwapPanelState();
}

class _SwapPanelState extends State<SwapPanel> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (!widget.isHost && c.source == MediaKind.file) c.source = MediaKind.link;
  }

  Future<void> _swap() async {
    final media = widget.controller.selection;
    if (media == null || _busy) return;
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
    if (error == null) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      key: const ValueKey('swap-panel'),
      elevation: 12,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Change video', style: t.titleLarge)),
                IconButton(
                    tooltip: 'Close (Esc)', icon: const Icon(Icons.close), onPressed: widget.onClose),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: MediaPicker(
                  controller: widget.controller,
                  jellyfin: widget.accounts,
                  enabled: !_busy,
                  allowFile: widget.isHost,
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
                        _error ?? (sel == null ? 'Pick something to watch' : 'Put up: ${sel.label}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyMedium?.copyWith(
                            color: _error != null ? Theme.of(context).colorScheme.error : null),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      key: const ValueKey('swap-go'),
                      onPressed: sel == null || _busy ? null : _swap,
                      icon: _busy
                          ? const SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.swap_horiz),
                      label: const Text('Put it up for everyone'),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
