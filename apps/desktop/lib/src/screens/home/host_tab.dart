import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/session_state.dart';
import 'connect_flow.dart';
import 'connect_status.dart';
import 'media_picker.dart';
import 'ui.dart';

/// Host form state, owned by the Home shell so it survives tab switches.
class HostFields {
  HostFields(ConnectForm f)
      : port = TextEditingController(text: f.hostPort),
        secret = TextEditingController(text: f.hostSecret),
        media = MediaPickerController(mediaPath: f.mediaPath, linkUrl: f.linkUrl);
  final TextEditingController port;
  final TextEditingController secret;
  final MediaPickerController media;

  void dispose() {
    port.dispose();
    secret.dispose();
    media.dispose();
  }
}

/// Below this width the server column moves under the media picker.
const hostStackBelow = 860.0;
const _columnWidth = 340.0;

/// Media picker as the main area; port/password/Host in a narrow column.
class HostTab extends StatelessWidget {
  final ConnectFlow flow;
  final HostFields fields;
  final VoidCallback? onOpenIntegrations;
  const HostTab(
      {super.key, required this.flow, required this.fields, this.onOpenIntegrations});

  void _host() => flow.submit(ConnectMode.host, (f) {
        final media = fields.media.selection;
        f
          ..hostPort = fields.port.text.trim()
          ..hostSecret = fields.secret.text
          ..mediaPath = media.mediaPath
          ..linkUrl = media.linkUrl;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) {
        final busy = flow.busy == ConnectMode.host;
        final picker = Column(
          key: const ValueKey('host-picker'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What to watch', style: t.titleMedium),
            const SizedBox(height: 12),
            MediaPicker(
              controller: fields.media,
              enabled: !busy,
              autofocus: true,
              onSubmit: _host,
              onOpenIntegrations: onOpenIntegrations,
            ),
          ],
        );
        final column = _ServerColumn(flow: flow, fields: fields, onHost: _host);
        return LayoutBuilder(builder: (context, box) {
          final stacked = box.maxWidth < hostStackBelow;
          return SingleChildScrollView(
            padding: kPagePadding,
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      picker,
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: kFieldMaxWidth),
                          child: column,
                        ),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: picker),
                      const SizedBox(width: 24),
                      SizedBox(width: _columnWidth, child: column),
                    ],
                  ),
          );
        });
      },
    );
  }
}

class _ServerColumn extends StatelessWidget {
  final ConnectFlow flow;
  final HostFields fields;
  final VoidCallback onHost;
  const _ServerColumn({required this.flow, required this.fields, required this.onHost});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    return Panel(
      key: const ValueKey('host-column'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.cast, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Text('Your server', style: t.titleMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text('Runs on this computer. Friends need this port reachable.',
              style: t.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: kGap),
          AbsorbPointer(
            absorbing: flow.busy == ConnectMode.host,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 120,
                    child: TextField(
                      key: const ValueKey('host-port'),
                      controller: fields.port,
                      decoration: fieldDecoration('Port'),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => flow.clearError(ConnectMode.host),
                      onSubmitted: (_) => onHost(),
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: fields.secret,
                  builder: (context, _) => TextField(
                    key: const ValueKey('host-password'),
                    controller: fields.secret,
                    obscureText: true,
                    decoration: fieldDecoration('Password').copyWith(
                      helperText:
                          fields.secret.text.isEmpty ? 'No password — anyone can join' : null,
                    ),
                    onSubmitted: (_) => onHost(),
                  ),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: fields.media,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_mediaSummary(fields.media.selection),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(color: Colors.grey)),
            ),
          ),
          ConnectFeedback(flow: flow, mode: ConnectMode.host),
          const SizedBox(height: kGap),
          ConnectButton(
              flow: flow, mode: ConnectMode.host, label: 'Host', onSubmit: onHost, expand: true),
          _HostedRecents(fields: fields, enabled: flow.busy == null),
        ],
      ),
    );
  }

  static String _mediaSummary(MediaSelection s) {
    final raw = s.linkUrl.isNotEmpty ? s.linkUrl : s.mediaPath;
    if (raw.isEmpty) return 'No media selected (optional).';
    final name = raw.split(RegExp(r'[/\\]')).lastWhere((p) => p.isNotEmpty, orElse: () => raw);
    return 'Playing: $name';
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
        padding: const EdgeInsets.only(top: kGap),
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
