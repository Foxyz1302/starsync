import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../../state/session_state.dart';
import 'connect_flow.dart';
import 'connect_status.dart';
import 'health_probe.dart';
import 'ui.dart';

/// Join form text, owned by the Home shell so it survives tab switches.
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

/// Smallest recent-server tile; the grid adds columns as the window widens.
const _minTileWidth = 300.0;

/// One compact address/port/password row, then recent servers with live
/// status, as a grid that fills the width.
class JoinTab extends StatelessWidget {
  final ConnectFlow flow;
  final JoinFields fields;
  final HealthGetter healthGet;
  const JoinTab(
      {super.key, required this.flow, required this.fields, required this.healthGet});

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
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) => SingleChildScrollView(
        padding: kPagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Join a friend’s server', style: t.titleMedium),
            const SizedBox(height: 12),
            AbsorbPointer(
              absorbing: flow.busy == ConnectMode.join,
              child: _joinRow(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kFieldMaxWidth),
                child: ConnectFeedback(flow: flow, mode: ConnectMode.join),
              ),
            ),
            const SizedBox(height: 32),
            Text('Recent servers', style: t.titleMedium),
            const SizedBox(height: 12),
            SignalBuilder(builder: (context) {
              final list = [
                for (final r in SessionState.instance.recents.value)
                  if (!r.hosted) r
              ];
              return RecentServersGrid(
                servers: list,
                enabled: flow.busy == null,
                healthGet: healthGet,
                onJoin: _joinRecent,
                onForget: SessionState.instance.forgetServer,
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _joinRow() {
    return Wrap(
      key: const ValueKey('join-row'),
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 280,
              child: TextField(
                key: const ValueKey('join-address'),
                controller: fields.host,
                decoration: fieldDecoration('Address', hint: 'IP or hostname'),
                onChanged: (_) => flow.clearError(ConnectMode.join),
                onSubmitted: (_) => _join(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text(':', style: TextStyle(fontSize: 18, color: Colors.grey)),
            ),
            SizedBox(
              width: 96,
              child: TextField(
                key: const ValueKey('join-port'),
                controller: fields.port,
                decoration: fieldDecoration('Port'),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _join(),
              ),
            ),
          ],
        ),
        SizedBox(
          width: 220,
          child: TextField(
            key: const ValueKey('join-password'),
            controller: fields.secret,
            obscureText: true,
            decoration: fieldDecoration('Password', hint: 'If the server has one'),
            onSubmitted: (_) => _join(),
          ),
        ),
        ConnectButton(flow: flow, mode: ConnectMode.join, label: 'Join', onSubmit: _join),
      ],
    );
  }
}

/// Recent servers as tiles; polls each one's `/health` every
/// [healthPollEvery] while mounted (i.e. while the Join tab is visible).
class RecentServersGrid extends StatefulWidget {
  final List<RecentServer> servers;
  final bool enabled;
  final HealthGetter healthGet;
  final ValueChanged<RecentServer> onJoin;
  final ValueChanged<RecentServer> onForget;
  const RecentServersGrid({
    super.key,
    required this.servers,
    required this.enabled,
    required this.healthGet,
    required this.onJoin,
    required this.onForget,
  });

  @override
  State<RecentServersGrid> createState() => _RecentServersGridState();
}

class _RecentServersGridState extends State<RecentServersGrid> {
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
  void didUpdateWidget(RecentServersGrid old) {
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
    if (widget.servers.isEmpty) return const _EmptyRecents();
    return LayoutBuilder(builder: (context, box) {
      final cols = ((box.maxWidth + kGap) / (_minTileWidth + kGap)).floor().clamp(1, 64);
      final width = (box.maxWidth - kGap * (cols - 1)) / cols;
      return Wrap(
        spacing: kGap,
        runSpacing: kGap,
        children: [
          for (final r in widget.servers)
            SizedBox(
              width: width,
              child: _RecentTile(
                key: ValueKey('recent-${r.key}'),
                server: r,
                health: _health[r.key],
                enabled: widget.enabled,
                onJoin: () => widget.onJoin(r),
                onForget: () => widget.onForget(r),
              ),
            ),
        ],
      );
    });
  }
}

class _RecentTile extends StatelessWidget {
  final RecentServer server;
  /// Null until the first probe answers.
  final ServerHealth? health;
  final bool enabled;
  final VoidCallback onJoin;
  final VoidCallback onForget;
  const _RecentTile({
    super.key,
    required this.server,
    required this.health,
    required this.enabled,
    required this.onJoin,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = theme.textTheme;
    final h = health;
    final address = '${server.host}:${server.port}';
    final title = h != null && h.name.isNotEmpty ? h.name : server.host;
    final (status, statusColor) = switch (h) {
      null => ('Checking…', Colors.grey),
      ServerHealth(online: true) => (
          '● online · ${h.viewers} watching',
          Colors.greenAccent.shade400
        ),
      _ => ('○ offline', Colors.grey),
    };
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onJoin : null,
        child: Tooltip(
          message: 'Join $address',
          waitDuration: const Duration(milliseconds: 600),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 6, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.dns_outlined, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium),
                    ),
                    if (server.secret.isNotEmpty)
                      const Tooltip(
                        message: 'Password saved',
                        child: Icon(Icons.lock_outline, size: 16, color: Colors.grey),
                      ),
                    IconButton(
                      tooltip: 'Forget',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: onForget,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 30, right: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: Colors.grey)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(status,
                                key: const ValueKey('recent-status'),
                                style: t.bodyMedium?.copyWith(color: statusColor)),
                          ),
                          if (h != null && h.needsUpdate)
                            Tooltip(
                              message: 'Server protocol ${h.proto}, this app '
                                  '${RelayConstants.protoVersion} — update so both match',
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: scheme.errorContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('needs update',
                                    style: t.labelSmall
                                        ?.copyWith(color: scheme.onErrorContainer)),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyRecents extends StatelessWidget {
  const _EmptyRecents();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Panel(
      key: const ValueKey('recents-empty'),
      child: Row(
        children: [
          const Icon(Icons.history, size: 28, color: Colors.grey),
          const SizedBox(width: kGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No recent servers yet', style: t.titleSmall),
                const SizedBox(height: 2),
                Text('Servers you join show up here with live status; click one to rejoin.',
                    style: t.bodySmall?.copyWith(color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
