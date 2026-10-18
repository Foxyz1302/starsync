import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../app/app_graph.dart';
import '../session/app_events.dart' show ActionFailed;
import '../session/invite.dart';
import '../widgets/copy_open.dart';

/// Your server in the members card. Not shared: "Only you can reach it"
/// and Invite (opens it and copies the invite link). Shared: where
/// friends can reach it ([YourServer.reach]: the internet address, with
/// whether the port needs forwarding, and this machine's home-network or
/// VPN address) to pick from, "Include the password" (off each time; the
/// password is never copied unless ticked), Copy invite link and Stop
/// sharing.
class YourInvite extends StatefulWidget {
  const YourInvite({super.key});

  @override
  State<YourInvite> createState() => _YourInviteState();
}

class _YourInviteState extends State<YourInvite> {
  /// The address picked (null: the invite's own, the best one).
  String? _picked;
  bool _withPassword = false;

  static String _kindLabel(AddressKind k) => switch (k) {
        AddressKind.public => 'Internet',
        AddressKind.lan => 'Home network',
        AddressKind.vpn => 'VPN',
      };

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final graph = AppScope.of(context);
    final yours = graph.yourServer;
    return SignalBuilder(builder: (context) {
      final invite = yours.shared.value;
      final reach = yours.reach.value;
      final busy = yours.busy.value || yours.port.value == null;
      final small = TextStyle(color: muted, fontSize: 12);
      if (invite == null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            key: const ValueKey('your-invite'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Text('Only you can reach it. Invite opens it to friends; nothing you watch stops.',
                    style: small),
              ),
              TextButton.icon(
                key: const ValueKey('copy-invite'),
                onPressed: busy ? null : () => inviteFriends(context),
                icon: const Icon(Icons.group_add_outlined, size: 16),
                label: const Text('Invite'),
              ),
            ],
          ),
        );
      }
      final choices = reach?.choices ?? [(host: invite.host, kind: addressKind(invite.host))];
      final picked = choices.any((c) => c.host == _picked) ? _picked! : invite.host;
      final kind = choices.where((c) => c.host == picked).firstOrNull?.kind ?? addressKind(picked);
      final secret = graph.forms.form.hostSecret;
      final local = reach?.local.firstOrNull;
      final note = switch (kind) {
        AddressKind.public when reach?.forwarding ?? false =>
          'This is your router\'s address. Friends elsewhere get in only when port ${invite.port} is '
              'forwarded on your router to this computer${local == null ? '' : ' ($local)'}.',
        AddressKind.public => 'This computer has this internet address itself; a firewall can still '
            'block port ${invite.port}.',
        AddressKind.lan => 'Works for friends on your network (same Wi-Fi or router).',
        AddressKind.vpn => 'Works for friends on the same VPN (Tailscale and the like).',
      };
      final noPublic = reach != null && !reach.looking && reach.public == null;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          key: const ValueKey('your-invite'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text('Friends join at', style: small),
            ),
            for (final c in choices)
              _AddressRow(
                key: ValueKey('invite-address-${c.host}'),
                label: _kindLabel(c.kind),
                address: invite.at(c.host).address,
                selected: c.host == picked,
                onTap: () => setState(() => _picked = c.host),
              ),
            if (reach?.looking ?? false)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Flexible(child: Text('Looking up your internet address…', style: small)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Text(
                key: const ValueKey('invite-note'),
                [
                  note,
                  if (noPublic)
                    "Couldn't find your internet address: friends elsewhere need port ${invite.port} "
                        'forwarded on your router, or a server they can all reach (like a VPS).',
                ].join(' '),
                style: small,
              ),
            ),
            if (secret.isNotEmpty)
              CheckboxListTile(
                key: const ValueKey('invite-with-password'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                controlAffinity: ListTileControlAffinity.leading,
                value: _withPassword,
                onChanged: (v) => setState(() => _withPassword = v ?? false),
                title: const Text('Include the password in the link'),
              ),
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  key: const ValueKey('copy-invite'),
                  onPressed: () {
                    final text = invite.at(picked).textWith(secret: _withPassword ? secret : '');
                    graph.joinOffers.copied(text);
                    copyToClipboard(context, text,
                        done: _withPassword ? 'Invite link copied, with the password' : 'Invite link copied');
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy invite link'),
                ),
                TextButton(
                  key: const ValueKey('stop-sharing'),
                  onPressed: busy ? null : () => yours.stopSharing(),
                  child: const Text('Stop sharing'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
              child: Text('Stop sharing sends everyone else out; you and Up next stay.', style: small),
            ),
          ],
        ),
      );
    });
  }
}

class _AddressRow extends StatelessWidget {
  final String label;
  final String address;
  final bool selected;
  final VoidCallback onTap;
  const _AddressRow(
      {super.key, required this.label, required this.address, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(children: [
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18, color: selected ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          SizedBox(width: 96, child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
          Expanded(child: Text(address, style: const TextStyle(fontFamily: 'monospace'))),
        ]),
      ),
    );
  }
}

/// Invite: opens your server to friends if it is not yet and copies the
/// invite link at the best address (the internet one when found, else
/// this machine's; never the password); a port that can't be opened is
/// a notice.
Future<void> inviteFriends(BuildContext context) async {
  final graph = AppScope.of(context);
  final Invite invite;
  try {
    invite = await graph.yourServer.invite();
  } catch (e) {
    final port = graph.forms.form.hostPort;
    graph.notifier.notify(ActionFailed(
        "couldn't open your server on port $port: $e — pick another port in Settings → Party & network"));
    return;
  }
  if (!context.mounted) return;
  graph.joinOffers.copied(invite.text);
  await copyToClipboard(context, invite.text, done: 'Invite link copied · ${invite.address}');
}
