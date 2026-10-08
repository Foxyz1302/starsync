import 'package:flutter/material.dart';

import '../screens/home/ui.dart';
import 'accounts.dart';
import 'browse_scope.dart';
import 'browser.dart';
import 'sign_in_panel.dart';

/// The Library's Jellyfin source: the library browser once a server is
/// linked, else an inline add-server panel.
class JellyfinPickerSource extends StatefulWidget {
  final JellyfinAccounts accounts;
  final BrowseController? controller;
  final JellyfinSelection? selected;
  final ValueChanged<JellyfinSelection> onSelect;
  final ValueChanged<JellyfinSelection> onPutUp;
  final VoidCallback? onOpenIntegrations;
  final BrowseStart? start;
  final bool libraryStrip;
  const JellyfinPickerSource({
    super.key,
    this.start,
    required this.accounts,
    required this.onSelect,
    required this.onPutUp,
    this.controller,
    this.selected,
    this.onOpenIntegrations,
    this.libraryStrip = true,
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
          controller: widget.controller,
          selected: widget.selected,
          onSelect: widget.onSelect,
          onPutUp: widget.onPutUp,
          onOpenIntegrations: widget.onOpenIntegrations,
          start: widget.start,
          libraryStrip: widget.libraryStrip,
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
