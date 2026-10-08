import 'package:flutter/material.dart';

import '../screens/home/ui.dart';
import 'accounts.dart';
import 'browser.dart' show JellyfinAvatar, StatusDot, showReconnectDialog;
import 'sign_in_panel.dart';

/// Integrations > Jellyfin: linked servers (avatar, status, default,
/// reconnect, sign out) and the inline add-server flow.
class JellyfinAccountsPanel extends StatefulWidget {
  final JellyfinAccounts accounts;
  final Duration pollInterval;
  const JellyfinAccountsPanel({
    super.key,
    required this.accounts,
    this.pollInterval = const Duration(seconds: 3),
  });

  @override
  State<JellyfinAccountsPanel> createState() => _JellyfinAccountsPanelState();
}

class _JellyfinAccountsPanelState extends State<JellyfinAccountsPanel> {
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    widget.accounts.ensureLoaded();
  }

  Future<void> _signOut(JellyfinAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign out of ${a.displayName}?'),
        content: const Text(
            'This app\'s sign-in is revoked on the server and the server is unlinked. '
            'You can add it again any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('jf-sign-out-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await widget.accounts.signOut(a.serverId);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.accounts,
      builder: (context, _) {
        final list = widget.accounts.accounts;
        return Panel(
          key: const ValueKey('jf-accounts'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.video_library_outlined,
                      size: 32, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: kGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Jellyfin', style: t.titleMedium),
                        const SizedBox(height: 4),
                        const Text(
                          'Browse your libraries in the Library tab and put up movies and episodes. '
                          'Sign in with Quick Connect or your password; several servers are fine.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: kGap),
                  if (!_adding)
                    FilledButton.icon(
                      key: const ValueKey('jf-add-server'),
                      onPressed: () => setState(() => _adding = true),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add server'),
                    ),
                ],
              ),
              if (list.isNotEmpty) const SizedBox(height: kGap),
              for (final a in list)
                _AccountTile(
                  accounts: widget.accounts,
                  account: a,
                  isDefault: widget.accounts.defaultServerId == a.serverId,
                  showDefault: list.length > 1,
                  onSignOut: () => _signOut(a),
                ),
              if (_adding) ...[
                const SizedBox(height: kGap),
                const Divider(height: 1),
                const SizedBox(height: kGap),
                JellyfinSignInPanel(
                  accounts: widget.accounts,
                  pollInterval: widget.pollInterval,
                  onCancel: () => setState(() => _adding = false),
                  onDone: (_) => setState(() => _adding = false),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount account;
  final bool isDefault;
  final bool showDefault;
  final VoidCallback onSignOut;
  const _AccountTile({
    required this.accounts,
    required this.account,
    required this.isDefault,
    required this.showDefault,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = accounts.statusOf(account.serverId);
    final statusText = switch (status) {
      JellyfinAccountStatus.online => 'Connected',
      JellyfinAccountStatus.offline => 'Offline',
      JellyfinAccountStatus.expired => 'Sign-in expired',
      JellyfinAccountStatus.checking => 'Checking…',
      JellyfinAccountStatus.unknown => 'Not checked',
    };
    return Padding(
      key: ValueKey('jf-account-${account.serverId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          JellyfinAvatar(accounts: accounts, account: account),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${account.userName} on ${account.displayName}', style: t.titleSmall),
                Row(children: [
                  StatusDot(status: status),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      [
                        statusText,
                        if (account.serverVersion.isNotEmpty) 'Jellyfin ${account.serverVersion}',
                        account.baseUrl,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: Colors.grey),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          if (showDefault)
            IconButton(
              key: ValueKey('jf-default-${account.serverId}'),
              tooltip: isDefault ? 'Default server' : 'Make default',
              onPressed: () => accounts.setDefault(account.serverId),
              icon: Icon(isDefault ? Icons.star : Icons.star_border,
                  color: isDefault ? Theme.of(context).colorScheme.primary : null),
            ),
          if (status == JellyfinAccountStatus.expired)
            FilledButton.tonal(
              key: ValueKey('jf-reconnect-${account.serverId}'),
              onPressed: () => showReconnectDialog(context, accounts, account),
              child: const Text('Reconnect'),
            )
          else if (status == JellyfinAccountStatus.offline)
            TextButton(
              onPressed: () => accounts.validate(account.serverId),
              child: const Text('Retry'),
            ),
          const SizedBox(width: 4),
          TextButton(
            key: ValueKey('jf-sign-out-${account.serverId}'),
            onPressed: onSignOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
