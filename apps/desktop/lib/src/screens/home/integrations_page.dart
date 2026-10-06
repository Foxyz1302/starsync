import 'package:flutter/material.dart';

import '../../jellyfin/accounts.dart';
import '../../jellyfin/accounts_panel.dart';
import 'ui.dart';

class IntegrationsPage extends StatelessWidget {
  /// Defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  const IntegrationsPage({super.key, this.jellyfin});

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      maxWidth: 820,
      children: [
        const PageTitle('Integrations',
            subtitle: 'Connect media libraries to pick what to watch.'),
        JellyfinAccountsPanel(accounts: jellyfin ?? JellyfinAccounts.instance),
      ],
    );
  }
}
