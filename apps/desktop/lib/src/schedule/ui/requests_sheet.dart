import 'package:flutter/material.dart';

import '../../shell/avatar.dart';
import '../animeflow.dart';

// The Schedule page's side sheet: AnimeFlow requests (everyone's for the
// owner, who can retry failed ones and decline the rest; own otherwise).

Color requestColor(RequestStatus s) => switch (s) {
  RequestStatus.pending || RequestStatus.searching => Colors.amber,
  RequestStatus.approved => Colors.lightBlueAccent,
  RequestStatus.rejected || RequestStatus.failed => Colors.redAccent,
  RequestStatus.done => Colors.greenAccent,
};

String requestWhat(AnimeFlowRequest r) => switch (r.kind) {
  RequestKind.series => r.title,
  RequestKind.season => '${r.title} · season ${r.season ?? '?'}',
  RequestKind.episode => '${r.title} · S${r.season ?? '?'}E${r.episode ?? '?'}',
};

class RequestsSheet extends StatelessWidget {
  /// Scope manage: everyone's requests, Retry and Decline.
  final bool owner;

  /// Null while loading.
  final List<AnimeFlowRequest>? requests;
  final String? error;

  /// Our own name, for requests without a user name.
  final String selfName;

  /// Requests with a call in flight.
  final Set<int> busy;
  final void Function(AnimeFlowRequest r) onRetry;
  final void Function(AnimeFlowRequest r) onDecline;
  final VoidCallback onClose;

  const RequestsSheet({
    super.key,
    required this.owner,
    required this.requests,
    required this.selfName,
    required this.onRetry,
    required this.onDecline,
    required this.onClose,
    this.error,
    this.busy = const {},
  });

  Widget _tile(BuildContext context, AnimeFlowRequest r) {
    final scheme = Theme.of(context).colorScheme;
    final who = r.userName ?? (selfName.isEmpty ? 'you' : selfName);
    final canRetry = owner && r.status == RequestStatus.failed;
    final canDecline =
        owner &&
        (r.status == RequestStatus.pending ||
            r.status == RequestStatus.approved ||
            r.status == RequestStatus.searching);
    final inFlight = busy.contains(r.id);
    return Padding(
      key: ValueKey('request-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusAvatar(
            info: AvatarInfo(name: who, color: colorForName(who)),
            size: 32,
            ring: false,
            badges: false,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(requestWhat(r), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(who, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                    Pill(r.status.name, requestColor(r.status)),
                  ],
                ),
                if (r.reason != null && r.reason!.isNotEmpty)
                  Text(r.reason!, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
                if (canRetry || canDecline)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        if (canRetry)
                          FilledButton.tonal(
                            key: ValueKey('retry-${r.id}'),
                            onPressed: inFlight ? null : () => onRetry(r),
                            child: const Text('Retry'),
                          ),
                        if (canDecline)
                          TextButton(
                            key: ValueKey('decline-${r.id}'),
                            onPressed: inFlight ? null : () => onDecline(r),
                            child: const Text('Decline'),
                          ),
                        if (inFlight) ...[
                          const SizedBox(width: 8),
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reqs = requests;
    return Material(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 16),
        children: [
          Row(
            children: [
              Text(
                owner ? 'Requests' : 'My requests',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('requests-close'),
                onPressed: onClose,
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          Text(
            owner
                ? 'Everyone\'s requests. AnimeFlow approves them automatically; you can decline or retry.'
                : 'AnimeFlow downloads requests automatically; they appear on Jellyfin when done.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!, style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
          if (reqs == null && error == null)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (reqs != null && reqs.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Text('No requests yet', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ),
          for (final r in reqs ?? const <AnimeFlowRequest>[]) _tile(context, r),
        ],
      ),
    );
  }
}
