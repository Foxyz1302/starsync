import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/session_state.dart';
import '../../update/update_controller.dart';
import 'connect_flow.dart';
import 'profile.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Below this width the Join/Host cards stack.
const _stackBelow = 700.0;

const _videoExtensions = ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts'];

class HomePage extends StatefulWidget {
  final UpdateController? updates;
  const HomePage({super.key, this.updates});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _flow = ConnectFlow();
  late final _f = SessionState.instance.lastForm;
  late final _joinHost = TextEditingController(text: _f.host);
  late final _joinPort = TextEditingController(text: _f.port);
  late final _joinSecret = TextEditingController(text: _f.secret);
  late final _hostPort = TextEditingController(text: _f.hostPort);
  late final _hostSecret = TextEditingController(text: _f.hostSecret);
  late final _media =
      TextEditingController(text: _f.linkUrl.isNotEmpty ? _f.linkUrl : _f.mediaPath);
  late final void Function() _stopKickWatch;
  late final void Function() _stopCrashWatch;
  bool _dialogOpen = false;
  String? _lastKickShown;

  @override
  void initState() {
    super.initState();
    _flow.onKicked = _showKickedDialog;
    // Back from a session that ended in a kick: say so.
    _stopKickWatch = effect(() {
      final kick = SessionState.instance.coordinator.kickReason.value;
      if (kick == null || kick.isEmpty) {
        _lastKickShown = null;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _showKickedDialog(kick));
    });
    // Back from a session whose hosted server crashed: say so on the Host card.
    _stopCrashWatch = effect(() {
      final crash = SessionState.instance.serverCrash.value;
      if (crash == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SessionState.instance.serverCrash.value = null;
        if (mounted) _flow.showError(ConnectMode.host, CardError('Server crashed', crash));
      });
    });
  }

  @override
  void dispose() {
    _stopKickWatch();
    _stopCrashWatch();
    _flow.dispose();
    for (final c in [_joinHost, _joinPort, _joinSecret, _hostPort, _hostSecret, _media]) {
      c.dispose();
    }
    super.dispose();
  }

  void _join() => _flow.submit(ConnectMode.join, (f) {
        f
          ..host = _joinHost.text
          ..port = _joinPort.text.trim()
          ..secret = _joinSecret.text;
      });

  void _host() => _flow.submit(ConnectMode.host, (f) {
        f
          ..hostPort = _hostPort.text.trim()
          ..hostSecret = _hostSecret.text
          ..mediaPath = _media.text.trim()
          ..linkUrl = '';
      });

  void _useRecent(RecentServer r) {
    if (r.hosted) {
      _hostPort.text = r.port;
      _hostSecret.text = r.secret;
      setState(() {});
      return;
    }
    _joinHost.text = r.host;
    _joinPort.text = r.port;
    _joinSecret.text = r.secret;
    _join();
  }

  Future<void> _browseMedia() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Pick media file',
        type: FileType.custom,
        allowedExtensions: _videoExtensions,
      );
      final path = files.isEmpty ? null : files.first.path;
      if (path != null && mounted) setState(() => _media.text = path);
    } catch (e) {
      if (!mounted) return;
      _flow.notices[ConnectMode.host] =
          'File dialog unavailable (${e.runtimeType}) — paste the path instead';
      setState(() {});
    }
  }

  Future<void> _showKickedDialog(String reason) async {
    if (!mounted || _dialogOpen || reason == _lastKickShown) return;
    _lastKickShown = reason;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('You were removed'),
          content: Text(reason.isEmpty ? 'The host removed you from the server.' : reason),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _flow,
      builder: (context, _) => PageScroll(
        children: [
          Row(
            children: [
              const ProfileChip(),
              const Spacer(),
              UpdateIndicator(controller: widget.updates),
            ],
          ),
          const SizedBox(height: 24),
          LayoutBuilder(builder: (context, box) {
            final stacked = box.maxWidth < _stackBelow;
            final join = _joinCard(context, fill: !stacked);
            final host = _hostCard(context, fill: !stacked);
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [join, const SizedBox(height: kGap), host],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: join),
                  const SizedBox(width: kGap),
                  Expanded(child: host),
                ],
              ),
            );
          }),
          _recents(context),
        ],
      ),
    );
  }

  Widget _joinCard(BuildContext context, {required bool fill}) {
    return _ConnectCard(
      key: const ValueKey('join-card'),
      icon: Icons.login,
      title: 'Join',
      subtitle: 'Connect to a friend’s server.',
      mode: ConnectMode.join,
      flow: _flow,
      action: 'Join',
      onSubmit: _join,
      fill: fill,
      fields: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _joinHost,
                decoration: fieldDecoration('Address', hint: 'IP or hostname'),
                onChanged: (_) => _flow.clearError(ConnectMode.join),
                onSubmitted: (_) => _join(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _joinPort,
                decoration: fieldDecoration('Port'),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _join(),
              ),
            ),
          ],
        ),
        TextField(
          controller: _joinSecret,
          obscureText: true,
          decoration: fieldDecoration('Password (optional)'),
          onSubmitted: (_) => _join(),
        ),
      ],
    );
  }

  Widget _hostCard(BuildContext context, {required bool fill}) {
    return _ConnectCard(
      key: const ValueKey('host-card'),
      icon: Icons.cast,
      title: 'Host',
      subtitle: 'Run the server here. Your friends need this port open.',
      mode: ConnectMode.host,
      flow: _flow,
      action: 'Host',
      onSubmit: _host,
      fill: fill,
      fields: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: TextField(
                controller: _hostPort,
                decoration: fieldDecoration('Port'),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _host(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ListenableBuilder(
                listenable: _hostSecret,
                builder: (context, _) => TextField(
                  controller: _hostSecret,
                  obscureText: true,
                  decoration: fieldDecoration('Password (optional)').copyWith(
                    helperText: _hostSecret.text.isEmpty
                        ? 'No password — anyone can join'
                        : null,
                  ),
                  onSubmitted: (_) => _host(),
                ),
              ),
            ),
          ],
        ),
        TextField(
          controller: _media,
          decoration: fieldDecoration(
            'Media',
            hint: 'File path or http(s) link — optional',
            suffix: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton(onPressed: _browseMedia, child: const Text('Browse')),
            ),
          ),
          onSubmitted: (_) => _host(),
        ),
      ],
    );
  }

  Widget _recents(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final list = SessionState.instance.recents.value;
      if (list.isEmpty) return const SizedBox.shrink();
      final busy = _flow.busy != null;
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recent',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in list)
                  InputChip(
                    key: ValueKey('recent-${r.key}'),
                    avatar: Icon(r.hosted ? Icons.cast : Icons.dns_outlined, size: 18),
                    label: Text(r.hosted ? 'Hosted on :${r.port}' : '${r.host}:${r.port}'),
                    tooltip: r.hosted ? 'Fill the Host card' : 'Join ${r.host}:${r.port}',
                    isEnabled: !busy,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onPressed: () => _useRecent(r),
                    deleteButtonTooltipMessage: 'Forget',
                    onDeleted: () => SessionState.instance.forgetServer(r),
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _ConnectCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final ConnectMode mode;
  final ConnectFlow flow;
  final String action;
  final VoidCallback onSubmit;
  final List<Widget> fields;
  // Side by side: push the button to the bottom so both cards line up.
  final bool fill;
  const _ConnectCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.mode,
    required this.flow,
    required this.action,
    required this.onSubmit,
    required this.fields,
    required this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busyHere = flow.busy == mode;
    final busyElsewhere = flow.busy != null && !busyHere;
    final error = flow.errors[mode];
    final notice = flow.notices[mode];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Text(title, style: theme.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: kGap),
          AbsorbPointer(
            absorbing: busyHere,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: fields,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(error: error),
          ] else if (notice != null) ...[
            const SizedBox(height: 12),
            Text(notice, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ],
          if (fill) const Spacer(),
          const SizedBox(height: kGap),
          if (busyHere) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(mode == ConnectMode.host ? 'Starting server…' : 'Connecting…',
                      style: theme.textTheme.bodySmall),
                ),
                TextButton(onPressed: flow.cancel, child: const Text('Cancel')),
              ],
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: busyElsewhere ? null : onSubmit,
                child: Text(action),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final CardError error;
  const _ErrorBox({required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText.rich(
              TextSpan(children: [
                TextSpan(
                    text: '${error.title}\n',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: error.message),
              ]),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
