import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../jellyfin/accounts.dart';
import '../../state/session_state.dart';
import 'connect_flow.dart';
import 'connect_status.dart';
import 'media_picker.dart';
import 'ui.dart';

/// Host form state, owned by the Home shell so it survives tab switches.
class HostFields {
  HostFields(ConnectForm f, {JellyfinAccounts? jellyfin})
      : jellyfin = jellyfin ?? JellyfinAccounts.instance,
        port = TextEditingController(text: f.hostPort),
        secret = TextEditingController(text: f.hostSecret),
        media = MediaPickerController(mediaPath: f.mediaPath, linkUrl: f.linkUrl) {
    // The last Jellyfin pick lives in the Jellyfin box (the connect form
    // only knows links and files); restore it once that box is read.
    final noMedia = f.mediaPath.isEmpty && f.linkUrl.isEmpty;
    this.jellyfin.ensureLoaded().then((_) {
      final pick = this.jellyfin.lastPick;
      if (_disposed || pick == null || media.jellyfin != null) return;
      if (this.jellyfin.account(pick.serverId) == null) return;
      if (noMedia) {
        media.pickJellyfin(pick);
      } else {
        final source = media.source;
        media.pickJellyfin(pick);
        media.source = source;
      }
    });
  }
  final JellyfinAccounts jellyfin;
  final TextEditingController port;
  final TextEditingController secret;
  final MediaPickerController media;
  /// Jellyfin browser enlarged: the server column shrinks to a bar.
  final browserExpanded = ValueNotifier(false);
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    port.dispose();
    secret.dispose();
    media.dispose();
    browserExpanded.dispose();
  }
}

/// INTERIM(jellyfin-protocol): until the protocol carries a Jellyfin item,
/// the host plays it as a link: this install's authorised static stream URL
/// (token in the query, so viewers stream with the host's sign-in and the
/// URL must not be persisted). Throws [FormatException] with a user-facing
/// message when the server is not linked any more.
String interimJellyfinLink(JellyfinAccounts accounts, JellyfinMedia media) {
  final client = accounts.clientFor(media.serverId);
  if (client == null) {
    throw const FormatException('that Jellyfin server is not linked any more — pick again');
  }
  if (accounts.statusOf(media.serverId) == JellyfinAccountStatus.expired) {
    throw const FormatException('Jellyfin sign-in expired — reconnect it in Integrations');
  }
  return client.streamUrl(media.itemId, mediaSourceId: media.mediaSourceId).toString();
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

  void _host() {
    if (flow.busy != null) return;
    final media = fields.media.selection;
    String? link;
    if (media is JellyfinMedia) {
      try {
        link = interimJellyfinLink(fields.jellyfin, media);
      } on FormatException catch (e) {
        flow.showError(ConnectMode.host, CardError('Check the form', e.message));
        return;
      }
      fields.jellyfin.rememberPick(media);
    }
    flow.submit(
      ConnectMode.host,
      (f) => f
        ..hostPort = fields.port.text.trim()
        ..hostSecret = fields.secret.text
        ..mediaPath = media is FileMedia ? media.path : ''
        ..linkUrl = media is LinkMedia ? media.url : '',
      linkOverride: link,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([flow, fields.media, fields.browserExpanded]),
      builder: (context, _) {
        final busy = flow.busy == ConnectMode.host;
        final jellyfin = fields.media.source == MediaKind.jellyfin;
        final expanded = jellyfin && fields.browserExpanded.value;
        Widget picker({required bool fill}) {
          final p = MediaPicker(
            controller: fields.media,
            enabled: !busy,
            autofocus: true,
            onSubmit: _host,
            onOpenIntegrations: onOpenIntegrations,
            jellyfin: fields.jellyfin,
            expanded: expanded,
            onToggleExpanded: () => fields.browserExpanded.value = !fields.browserExpanded.value,
          );
          return Column(
            key: const ValueKey('host-picker'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('What to watch', style: t.titleMedium),
              const SizedBox(height: 12),
              fill ? Expanded(child: p) : p,
            ],
          );
        }

        final column = _ServerColumn(flow: flow, fields: fields, onHost: _host);
        return LayoutBuilder(builder: (context, box) {
          final stacked = box.maxWidth < hostStackBelow;
          // Jellyfin browser: fills the height (lazy grids need a bounded
          // viewport); the form sits beside it or, enlarged, in a bar below.
          if (expanded) {
            return Padding(
              padding: kPagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: picker(fill: true)),
                  const SizedBox(height: 12),
                  _HostBar(flow: flow, fields: fields, onHost: _host),
                ],
              ),
            );
          }
          if (jellyfin && !stacked) {
            return Padding(
              padding: kPagePadding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: picker(fill: true)),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: _columnWidth,
                    child: SingleChildScrollView(child: column),
                  ),
                ],
              ),
            );
          }
          return SingleChildScrollView(
            padding: kPagePadding,
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      picker(fill: false),
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
                      Expanded(child: picker(fill: false)),
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
              child: Text(mediaSummary(fields.media.selection),
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

}

String mediaSummary(PickedMedia? s) =>
    s == null ? 'No media selected (optional).' : 'Playing: ${s.label}';

/// Enlarged-browser mode: what is picked, port, password and Host in one
/// row under the browser.
class _HostBar extends StatelessWidget {
  final ConnectFlow flow;
  final HostFields fields;
  final VoidCallback onHost;
  const _HostBar({required this.flow, required this.fields, required this.onHost});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Panel(
      key: const ValueKey('host-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.cast, size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(mediaSummary(fields.media.selection),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium),
              ),
              const SizedBox(width: 12),
              AbsorbPointer(
                absorbing: flow.busy == ConnectMode.host,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: fields.port,
                        decoration: fieldDecoration('Port'),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => flow.clearError(ConnectMode.host),
                        onSubmitted: (_) => onHost(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 200,
                      child: TextField(
                        controller: fields.secret,
                        obscureText: true,
                        decoration: fieldDecoration('Password', hint: 'none = open'),
                        onSubmitted: (_) => onHost(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ConnectButton(flow: flow, mode: ConnectMode.host, label: 'Host', onSubmit: onHost),
            ],
          ),
          ConnectFeedback(flow: flow, mode: ConnectMode.host),
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
