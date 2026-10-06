import 'package:flutter/material.dart';

import '../screens/home/picked_media.dart';
import '../screens/home/ui.dart';
import 'accounts.dart';
import 'browser.dart';
import 'sign_in_panel.dart';

/// The media picker's Jellyfin source: the library browser once a server
/// is linked, else an inline add-server panel.
class JellyfinPickerSource extends StatefulWidget {
  final JellyfinAccounts accounts;
  final JellyfinMedia? selected;
  final ValueChanged<JellyfinMedia> onPick;
  final VoidCallback? onOpenIntegrations;
  final VoidCallback? onToggleExpanded;
  final bool expanded;
  const JellyfinPickerSource({
    super.key,
    required this.accounts,
    required this.onPick,
    this.selected,
    this.onOpenIntegrations,
    this.onToggleExpanded,
    this.expanded = false,
  });

  @override
  State<JellyfinPickerSource> createState() => _JellyfinPickerSourceState();
}

class _JellyfinPickerSourceState extends State<JellyfinPickerSource> {
  @override
  void initState() {
    super.initState();
    widget.accounts.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.accounts,
      builder: (context, _) {
        final a = widget.accounts;
        if (!a.loaded) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (a.isEmpty) return _LinkFirst(accounts: a, onOpenIntegrations: widget.onOpenIntegrations);
        return JellyfinBrowser(
          key: const ValueKey('media-jellyfin'),
          accounts: a,
          selected: widget.selected,
          onPick: widget.onPick,
          onOpenIntegrations: widget.onOpenIntegrations,
          onToggleExpanded: widget.onToggleExpanded,
          expanded: widget.expanded,
        );
      },
    );
  }
}

class _LinkFirst extends StatelessWidget {
  final JellyfinAccounts accounts;
  final VoidCallback? onOpenIntegrations;
  const _LinkFirst({required this.accounts, this.onOpenIntegrations});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const ValueKey('media-jellyfin'),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Link a Jellyfin server to browse it here. '
                    'You can manage linked servers in Integrations.',
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: kGap),
                JellyfinSignInPanel(accounts: accounts),
                if (onOpenIntegrations != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        onPressed: onOpenIntegrations, child: const Text('Open Integrations')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
