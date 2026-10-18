import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../app/app_graph.dart';
import '../session/app_events.dart' show ActionFailed;
import '../session/invite.dart';
import '../widgets/copy_open.dart';

/// Your server in the members card. Not shared: "Only you can reach it"
/// and Invite (opens it and copies the invite link). Shared: Copy invite
/// link (the bare `starsync://` link with the password, at the address
/// picked: the internet one when known, else this machine's), a short
/// line only when something needs the user ([YourServer.reach]: the port
/// needs forwarding, no internet address), Stop sharing, and the other
/// addresses (Internet / Home network / VPN) folded under a toggle.
class YourInvite extends StatefulWidget {
  const YourInvite({super.key});

  @override
  State<YourInvite> createState() => _YourInviteState();
}

class _YourInviteState extends State<YourInvite> {
  /// The address picked (null: the invite's own, the best one).
  String? _picked;
  bool _others = false;

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
      final looking = reach?.looking ?? false;
      final note = switch (kind) {
        AddressKind.public when reach?.forwarding ?? false =>
          'Friends outside your home network need port ${invite.port} forwarded to this computer.',
        AddressKind.public => null,
        _ when reach != null && !looking && reach.public == null =>
          "Couldn't find your internet address: this link works on your home network only.",
        _ => null,
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          key: const ValueKey('your-invite'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Tooltip(
                  message: invite.at(picked).address,
                  child: FilledButton.icon(
                    key: const ValueKey('copy-invite'),
                    onPressed: () {
                      final text = yours.inviteLink(invite.at(picked));
                      graph.joinOffers.copied(text);
                      copyToClipboard(context, text, done: 'Invite link copied');
                    },
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Copy invite link'),
                  ),
                ),
                Tooltip(
                  message: 'Sends everyone else out; you and Up next stay',
                  child: TextButton(
                    key: const ValueKey('stop-sharing'),
                    onPressed: busy ? null : () => yours.stopSharing(),
                    child: const Text('Stop sharing'),
                  ),
                ),
              ],
            ),
            if (looking)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Row(children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Flexible(child: Text('Looking up your internet address…', style: small)),
                ]),
              )
            else if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(note, key: const ValueKey('invite-note'), style: small),
              ),
            if (choices.length > 1) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                key: const ValueKey('invite-other-addresses'),
                style: TextButton.styleFrom(
                  foregroundColor: muted,
                  visualDensity: VisualDensity.compact,
                  textStyle: Theme.of(context).textTheme.bodySmall,
                ),
                onPressed: () => setState(() => _others = !_others),
                icon: Icon(_others ? Icons.expand_less : Icons.expand_more, size: 16),
                label: const Text('Other addresses'),
              ),
              if (_others)
                for (final c in choices)
                  _AddressRow(
                    key: ValueKey('invite-address-${c.host}'),
                    label: _kindLabel(c.kind),
                    address: invite.at(c.host).address,
                    selected: c.host == picked,
                    onTap: () => setState(() => _picked = c.host),
                  ),
            ],
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
/// bare invite link (with the password, when one is set) at the best
/// address (the internet one when found, else this machine's); a port
/// that can't be opened is a notice.
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
  final text = graph.yourServer.inviteLink(invite);
  graph.joinOffers.copied(text);
  await copyToClipboard(context, text, done: 'Invite link copied');
}
