import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show RelayConstants;

import '../screens/home/connect_flow.dart';
import '../screens/home/connect_status.dart';
import '../screens/home/health_probe.dart';
import '../state/session_state.dart';
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

/// Host card text, owned by the shell so it survives the card closing.
class HostFields {
  HostFields(ConnectForm f)
      : port = TextEditingController(text: f.hostPort),
        secret = TextEditingController(text: f.hostSecret);
  final TextEditingController port;
  final TextEditingController secret;

  void dispose() {
    port.dispose();
    secret.dispose();
  }
}

/// The strip's Join / Host buttons (and solo's Invite friends, the Host
/// card): a card over the window. It closes itself once the attempt got
/// in; a failed one shows its error inside.
Future<void> showConnectCard(
  BuildContext context, {
  required ConnectMode mode,
  required ConnectFlow flow,
  required JoinFields join,
  required HostFields host,
  HealthGetter healthGet = defaultHealthGet,
}) =>
    showPopover<void>(
      context,
      dim: true,
      at: const Alignment(0.8, -0.75),
      child: _CloseWhenOnline(
        child: mode == ConnectMode.host
            ? HostCard(flow: flow, fields: host)
            : JoinCard(flow: flow, fields: join, healthGet: healthGet),
      ),
    );

class _CloseWhenOnline extends StatefulWidget {
  final Widget child;
  const _CloseWhenOnline({required this.child});

  @override
  State<_CloseWhenOnline> createState() => _CloseWhenOnlineState();
}

class _CloseWhenOnlineState extends State<_CloseWhenOnline> {
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    _stop = effect(() {
      final s = SessionState.instance;
      // Solo is in a session too: wait until it is a hosted server.
      if (s.route.value != AppRoute.session || s.solo.value || s.switching.value) return;
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

/// Card frame shared by Join and Host.
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
/// password.
class JoinCard extends StatelessWidget {
  final ConnectFlow flow;
  final JoinFields fields;
  final HealthGetter healthGet;
  const JoinCard({super.key, required this.flow, required this.fields, this.healthGet = defaultHealthGet});

  void _join() => flow.submit(ConnectMode.join, (f) {
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) {
        final busy = flow.busy == ConnectMode.join;
        return _Card(
          title: 'Join a friend',
          children: [
            SignalBuilder(builder: (context) {
              final list = [
                for (final r in SessionState.instance.recents.value)
                  if (!r.hosted) r
              ];
              if (list.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Recent', style: TextStyle(color: Colors.grey)),
                  RecentServerRows(
                    servers: list,
                    enabled: flow.busy == null,
                    healthGet: healthGet,
                    onJoin: _joinRecent,
                    onForget: SessionState.instance.forgetServer,
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
                          decoration: _dense.copyWith(labelText: 'Address', hintText: 'IP or hostname'),
                          onChanged: (_) => flow.clearError(ConnectMode.join),
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
            ConnectButton(flow: flow, mode: ConnectMode.join, label: 'Join', onSubmit: _join, expand: true),
            ConnectFeedback(flow: flow, mode: ConnectMode.join),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Your friend gives you the address and password. No account or Jellyfin needed.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Port and password; what to watch is picked afterwards, in the library.
class HostCard extends StatelessWidget {
  final ConnectFlow flow;
  final HostFields fields;
  const HostCard({super.key, required this.flow, required this.fields});

  void _host() => flow.submit(
        ConnectMode.host,
        (f) => f
          ..hostPort = fields.port.text.trim()
          ..hostSecret = fields.secret.text,
      );

  @override
  Widget build(BuildContext context) {
    // From a solo session this is "Invite friends": same server settings,
    // and what plays carries over.
    final solo = SessionState.instance.solo.peek();
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) => _Card(
        title: solo ? 'Invite friends' : 'Host a server',
        children: [
          AbsorbPointer(
            absorbing: flow.busy == ConnectMode.host,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('host-port'),
                  controller: fields.port,
                  autofocus: true,
                  decoration: _dense.copyWith(labelText: 'Port', hintText: '8080'),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => flow.clearError(ConnectMode.host),
                  onSubmitted: (_) => _host(),
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: fields.secret,
                  builder: (context, _) => TextField(
                    key: const ValueKey('host-password'),
                    controller: fields.secret,
                    obscureText: true,
                    decoration: _dense.copyWith(
                      labelText: 'Password (optional)',
                      helperText: fields.secret.text.isEmpty ? 'No password — anyone can join' : null,
                    ),
                    onSubmitted: (_) => _host(),
                  ),
                ),
                _HostedRecents(fields: fields, enabled: flow.busy == null),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ConnectButton(
              flow: flow, mode: ConnectMode.host, label: solo ? 'Start hosting' : 'Host', onSubmit: _host, expand: true),
          ConnectFeedback(flow: flow, mode: ConnectMode.host),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              solo
                  ? 'Your video keeps playing from where it is; friends join with your address.'
                  : 'You pick what to watch afterwards, in the library.',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ports hosted before: one click refills port and password.
class _HostedRecents extends StatelessWidget {
  final HostFields fields;
  final bool enabled;
  const _HostedRecents({required this.fields, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final list = [
        for (final r in SessionState.instance.recents.value)
          if (r.hosted) r
      ];
      if (list.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in list)
              InputChip(
                key: ValueKey('recent-${r.key}'),
                avatar: Icon(r.secret.isEmpty ? Icons.history : Icons.lock_outline, size: 16),
                label: Text('Port ${r.port}'),
                tooltip: 'Use port ${r.port} again',
                isEnabled: enabled,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                onPressed: () {
                  fields.port.text = r.port;
                  fields.secret.text = r.secret;
                },
                deleteButtonTooltipMessage: 'Forget',
                onDeleted: () => SessionState.instance.forgetServer(r),
              ),
          ],
        ),
      );
    });
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
              message: 'Server protocol ${h.proto}, this app '
                  '${RelayConstants.protoVersion} — update so both match',
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
