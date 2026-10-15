import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../app/app_graph.dart';
import '../screens/home/connect_flow.dart';
import '../screens/home/connect_status.dart';
import '../screens/home/health_probe.dart';
import '../session/invite.dart' show addressIn;
import '../session/navigation.dart' show Place;
import '../state/connect_prefs.dart';
import '../update/update_controller.dart';
import 'motion.dart';

/// Join card text, owned by the shell so it survives the card closing.
class JoinFields {
  JoinFields(ConnectForm f)
      : host = TextEditingController(text: f.host),
        port = TextEditingController(text: f.port),
        secret = TextEditingController(text: f.secret);
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController secret;

  void dispose() {
    host.dispose();
    port.dispose();
    secret.dispose();
  }
}

/// The strip's Join a friend: a card over the window. It closes itself
/// once the join got in; a failed one shows its error inside.
Future<void> showJoinCard(
  BuildContext context, {
  required ConnectFlow flow,
  required JoinFields join,
  HealthGetter healthGet = defaultHealthGet,
  UpdateController? updates,
}) =>
    showPopover<void>(
      context,
      dim: true,
      at: const Alignment(0.8, -0.75),
      child: _CloseInFriends(
        child: JoinCard(flow: flow, fields: join, healthGet: healthGet, updates: updates),
      ),
    );

class _CloseInFriends extends StatefulWidget {
  final Widget child;
  const _CloseInFriends({required this.child});

  @override
  State<_CloseInFriends> createState() => _CloseInFriendsState();
}

class _CloseInFriendsState extends State<_CloseInFriends> {
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    final navigation = AppScope.of(context).navigation;
    var was = navigation.place.peek();
    _stop = effect(() {
      final place = navigation.place.value;
      final arrived = place == Place.friend && was != Place.friend;
      was = place;
      if (!arrived) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    });
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The card frame.
class _Card extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Card({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 360,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                ...children,
              ],
            ),
          ),
        ),
      );
}

const _dense = InputDecoration(isDense: true);

/// Recent servers as one-click rows (with live status), then address and
/// password. Pasting an invite into the address fills the port too.
class JoinCard extends StatelessWidget {
  final ConnectFlow flow;
  final JoinFields fields;
  final HealthGetter healthGet;
  final UpdateController? updates;
  const JoinCard({super.key, required this.flow, required this.fields, this.healthGet = defaultHealthGet, this.updates});

  void _join() => flow.submit((f) {
        f
          ..host = fields.host.text
          ..port = fields.port.text.trim()
          ..secret = fields.secret.text;
      });

  void _joinRecent(RecentServer r) {
    fields.host.text = r.host;
    fields.port.text = r.port;
    fields.secret.text = r.secret;
    _join();
  }

  /// An invite or "host:port" pasted into the address: split it.
  void _onAddress(String v) {
    flow.clearError();
    final a = addressIn(v);
    if (a == null || v.trim() == a.host) return;
    fields.host.text = a.host;
    fields.port.text = a.port;
  }

  @override
  Widget build(BuildContext context) {
    final forms = AppScope.of(context).forms;
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) {
        final busy = flow.busy;
        return _Card(
          title: 'Join a friend',
          children: [
            SignalBuilder(builder: (context) {
              final list = forms.recents.value;
              if (list.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Recent', style: TextStyle(color: Colors.grey)),
                  RecentServerRows(
                    servers: list,
                    enabled: !busy,
                    healthGet: healthGet,
                    onJoin: _joinRecent,
                    onForget: forms.forget,
                  ),
                  const Divider(),
                ],
              );
            }),
            AbsorbPointer(
              absorbing: busy,
              child: Column(
                key: const ValueKey('join-row'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('join-address'),
                          controller: fields.host,
                          autofocus: true,
                          decoration: _dense.copyWith(labelText: 'Address', hintText: 'IP, hostname or invite'),
                          onChanged: _onAddress,
                          onSubmitted: (_) => _join(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 72,
                        child: TextField(
                          key: const ValueKey('join-port'),
                          controller: fields.port,
                          decoration: _dense.copyWith(labelText: 'Port'),
                          keyboardType: TextInputType.number,
                          onSubmitted: (_) => _join(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('join-password'),
                    controller: fields.secret,
                    obscureText: true,
                    decoration: _dense.copyWith(labelText: 'Password (optional)'),
                    onSubmitted: (_) => _join(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ConnectButton(flow: flow, label: 'Join', onSubmit: _join, expand: true),
            ConnectFeedback(flow: flow, updates: updates),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Your friend gives you their invite (the address) and the password, if any. '
                'No account or Jellyfin needed. Your own server stays as it is.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Recent servers as rows; polls each one's `/health` every
/// [healthPollEvery] while mounted (i.e. while the Join card is open).
class RecentServerRows extends StatefulWidget {
  final List<RecentServer> servers;
  final bool enabled;
  final HealthGetter healthGet;
  final ValueChanged<RecentServer> onJoin;
  final ValueChanged<RecentServer> onForget;
  const RecentServerRows({
    super.key,
    required this.servers,
    required this.enabled,
    required this.healthGet,
    required this.onJoin,
    required this.onForget,
  });

  @override
  State<RecentServerRows> createState() => _RecentServerRowsState();
}

class _RecentServerRowsState extends State<RecentServerRows> {
  final _health = <String, ServerHealth>{};
  final _inFlight = <String>{};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pollAll();
    _timer = Timer.periodic(healthPollEvery, (_) => _pollAll());
  }

  @override
  void didUpdateWidget(RecentServerRows old) {
    super.didUpdateWidget(old);
    for (final r in widget.servers) {
      if (!_health.containsKey(r.key)) _poll(r);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _pollAll() {
    for (final r in widget.servers) {
      _poll(r);
    }
  }

  Future<void> _poll(RecentServer r) async {
    if (!_inFlight.add(r.key)) return;
    try {
      final h = await probeHealth(r.host, r.port, widget.healthGet);
      if (mounted) setState(() => _health[r.key] = h);
    } finally {
      _inFlight.remove(r.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in widget.servers)
          _RecentRow(
            key: ValueKey('recent-${r.key}'),
            server: r,
            health: _health[r.key],
            enabled: widget.enabled,
            onJoin: () => widget.onJoin(r),
            onForget: () => widget.onForget(r),
          ),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  final RecentServer server;
  /// Null until the first probe answers.
  final ServerHealth? health;
  final bool enabled;
  final VoidCallback onJoin;
  final VoidCallback onForget;
  const _RecentRow({
    super.key,
    required this.server,
    required this.health,
    required this.enabled,
    required this.onJoin,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = health;
    final address = '${server.host}:${server.port}';
    final title = h != null && h.name.isNotEmpty ? h.name : server.host;
    final (status, statusColor) = switch (h) {
      null => ('checking…', Colors.grey),
      ServerHealth(online: true) => ('● online · ${h.viewers} watching', Colors.greenAccent.shade400),
      _ => ('○ offline', Colors.grey),
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      enabled: enabled,
      leading: Icon(server.secret.isEmpty ? Icons.history : Icons.lock_outline, size: 18),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(address, style: const TextStyle(color: Colors.grey)),
          Text(status, key: const ValueKey('recent-status'), style: TextStyle(color: statusColor)),
          if (h != null && h.needsUpdate)
            Tooltip(
              message: versionGateText(h),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(6)),
                child: Text('needs update', style: TextStyle(fontSize: 11, color: scheme.onErrorContainer)),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Forget',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onForget,
            icon: const Icon(Icons.close),
          ),
          const Icon(Icons.login, size: 18),
        ],
      ),
      onTap: onJoin,
    );
  }
}
