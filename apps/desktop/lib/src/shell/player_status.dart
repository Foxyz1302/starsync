import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../session/health.dart';
import '../session/session_coordinator.dart';
import '../state/session_state.dart';
import 'avatar.dart';
import 'motion.dart';

/// What the player's status pill says, most pressing first.
enum StatusKind { kicked, reconnecting, problem, connecting, finished, loading, you, waiting }

/// The pill's button: stop reconnecting, retry, or mark yourself ready
/// (the whole pill).
enum StatusAction { cancel, retry, ready }

/// One status line: [text], a muted [detail], a coloured [tone] for
/// problems (warn, error), the members it is about ([who]; [self] for you)
/// and a loading [progress] (0..1).
class StatusView {
  final StatusKind kind;
  final String text;
  final String? detail;
  final HealthSeverity? tone;
  final List<MemberView> who;
  final bool self;
  final double? progress;
  final StatusAction? action;
  /// The mini player's shorter line.
  final String short;
  const StatusView(
    this.kind,
    this.text, {
    this.detail,
    this.tone,
    this.who = const [],
    this.self = false,
    this.progress,
    this.action,
    String? short,
  }) : short = short ?? text;
}

/// "Bob", "Bob and Mika", "Bob, Mika and Cleo", "Bob, Mika and 3 others".
String nameList(List<String> names) {
  if (names.length <= 1) return names.join();
  if (names.length <= 3) return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '${names[0]}, ${names[1]} and ${names.length - 2} others';
}

String _sentence(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The player's status from the session's signals; null when there is
/// nothing to say (playing, connected, everyone ready). [slowConnect]:
/// connecting has taken over 2 s.
StatusView? playerStatusFor({
  required HealthStatus health,
  bool reconnecting = false,
  String? kickReason,
  StateBroadcast? state,
  MemberView? self,
  bool slowConnect = false,
}) {
  if (kickReason != null) {
    return StatusView(StatusKind.kicked,
        kickReason.isEmpty ? 'You were removed from the server' : 'You were removed: $kickReason',
        tone: HealthSeverity.error, short: 'Removed from the server');
  }
  if (reconnecting) {
    return const StatusView(StatusKind.reconnecting, 'Reconnecting…',
        tone: HealthSeverity.warn, action: StatusAction.cancel);
  }
  if (health.severity == HealthSeverity.warn || health.severity == HealthSeverity.error) {
    return StatusView(StatusKind.problem, _sentence(health.message),
        tone: health.severity, action: StatusAction.retry);
  }
  if (slowConnect && health.severity == HealthSeverity.info && health.message.startsWith('connecting')) {
    return const StatusView(StatusKind.connecting, 'Connecting…');
  }
  final r = state;
  if (r == null || r.media == null || r.transport == 'playing') return null;
  if (r.transport == 'finished') {
    return const StatusView(StatusKind.finished, 'Finished · seek back or pick the next video', short: 'Finished');
  }
  // As the server holds playback: someone in the ready set short of the
  // minimum buffer.
  for (final m in r.members) {
    if (m.inSet && m.buffered < RelayConstants.minBufferSecs) {
      final you = self != null && m.id == self.id;
      return StatusView(StatusKind.loading, you ? 'Loading the video…' : '${m.name} is loading…',
          who: [m], self: you, progress: (m.buffered / RelayConstants.minBufferSecs).clamp(0.0, 1.0));
    }
  }
  if (self != null && !self.ready) {
    return StatusView(StatusKind.you, "Press Space when you're ready",
        who: [self], self: true, action: StatusAction.ready, short: 'Press Space when ready');
  }
  final active = [for (final m in r.members) if (!m.stale) m];
  final others = [
    for (final m in active)
      if ((self == null || m.id != self.id) && !(m.inSet && m.ready)) m,
  ];
  if (others.isEmpty) return null;
  final ready = active.where((m) => m.ready).length;
  return StatusView(StatusKind.waiting, 'Waiting for ${nameList([for (final m in others) m.name])}',
      who: others, detail: '$ready/${active.length} ready');
}

/// [playerStatusFor] from the session (tracked: call inside a builder).
StatusView? playerStatusNow({bool slowConnect = false}) {
  final c = SessionState.instance.coordinator;
  return playerStatusFor(
    health: c.health.value,
    reconnecting: c.reconnecting.value,
    kickReason: c.kickReason.value,
    state: c.serverState.value,
    self: c.selfMember.value,
    slowConnect: slowConnect,
  );
}

/// The player's one status pill (bottom centre): frosted dark glass with
/// one short line, the members it is about and at most one button. Fades
/// in and out; a different kind of status fades through, the pill resizing
/// around it.
class PlayerStatus extends StatefulWidget {
  const PlayerStatus({super.key});

  static const connectGrace = Duration(seconds: 2);

  @override
  State<PlayerStatus> createState() => _PlayerStatusState();
}

class _PlayerStatusState extends State<PlayerStatus> {
  Timer? _connectTimer;
  bool _slow = false;
  StatusView? _last;

  @override
  void dispose() {
    _connectTimer?.cancel();
    super.dispose();
  }

  // "Connecting…" only once it takes a while.
  void _trackConnecting(HealthStatus h) {
    final connecting = h.severity == HealthSeverity.info && h.message.startsWith('connecting');
    if (!connecting) {
      _connectTimer?.cancel();
      _connectTimer = null;
      _slow = false;
    } else if (_connectTimer == null && !_slow) {
      _connectTimer = Timer(PlayerStatus.connectGrace, () {
        if (mounted) setState(() => _slow = true);
      });
    }
  }

  void _act(SessionCoordinator coord, StatusAction a) {
    switch (a) {
      case StatusAction.cancel:
        coord.cancelReconnect();
      case StatusAction.retry:
        coord.retry();
      case StatusAction.ready:
        coord.toggleReady();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PartyWatch(builder: (context) {
      final coord = SessionState.instance.coordinator;
      _trackConnecting(coord.health.value);
      final view = playerStatusNow(slowConnect: _slow);
      if (view != null) _last = view;
      final shown = _last;
      final ready = view?.action == StatusAction.ready;
      return AnimatedOpacity(
        duration: easeTime,
        curve: ease,
        opacity: view == null ? 0 : 1,
        child: IgnorePointer(
          ignoring: view == null,
          child: shown == null
              ? const SizedBox.shrink()
              : MouseRegion(
                  cursor: ready ? SystemMouseCursors.click : MouseCursor.defer,
                  child: GestureDetector(
                    key: const ValueKey('player-status'),
                    onTap: ready ? coord.toggleReady : null,
                    child: PlayerGlass(
                      child: AnimatedSize(
                        duration: easeTime,
                        curve: ease,
                        child: fadeThrough(
                          _StatusLine(
                            key: ValueKey(shown.kind),
                            view: shown,
                            coord: coord,
                            onAction: (a) => _act(coord, a),
                          ),
                          expand: false,
                          alignment: Alignment.center,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      );
    });
  }
}

/// Frosted dark glass in a pill: the status pill, the unread chip.
class PlayerGlass extends StatelessWidget {
  final Widget child;
  const PlayerGlass({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(999);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: r,
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final StatusView view;
  final SessionCoordinator coord;
  final ValueChanged<StatusAction> onAction;
  const _StatusLine({super.key, required this.view, required this.coord, required this.onAction});

  static const _avatar = 24.0;

  Widget? _lead() {
    final v = view;
    switch (v.kind) {
      case StatusKind.kicked:
      case StatusKind.problem:
        final error = v.tone == HealthSeverity.error;
        return Icon(error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            size: 18, color: error ? Colors.redAccent.shade100 : Colors.amber);
      case StatusKind.reconnecting:
        return const _Spinner(color: Colors.amber);
      case StatusKind.connecting:
        return const _Spinner(color: Colors.white70);
      case StatusKind.finished:
        return null;
      case StatusKind.loading:
      case StatusKind.you:
      case StatusKind.waiting:
        final r = coord.serverState.value;
        final infos = [
          for (final m in v.who)
            v.self ? selfAvatarInfo(ready: m.ready, host: m.host) : memberAvatarInfo(m, r, coord),
        ];
        if (infos.isEmpty) return null;
        return infos.length == 1
            ? StatusAvatar(info: infos.first, size: _avatar, badges: false)
            : AvatarStack(members: infos, shown: 4, size: _avatar);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = view;
    final lead = _lead();
    final action = v.action == StatusAction.ready ? null : v.action;
    return Padding(
      padding: EdgeInsets.fromLTRB(lead == null ? 16 : 6, 6, action == null ? 16 : 6, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead != null) ...[
            SizedBox(height: _avatar, child: Center(child: lead)),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              v.text,
              key: const ValueKey('player-status-text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (v.progress != null) ...[
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(
                value: v.progress,
                strokeWidth: 2,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          ],
          if (v.detail != null) ...[
            const SizedBox(width: 8),
            Text(v.detail!, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w500)),
          ],
          if (action != null) ...[
            const SizedBox(width: 10),
            _PillButton(
              label: action == StatusAction.cancel ? 'Cancel' : 'Retry',
              onPressed: () => onAction(action),
            ),
          ],
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  final Color color;
  const _Spinner({required this.color});

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color));
}

class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _PillButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) => TextButton(
        key: ValueKey('player-status-$label'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Colors.white12,
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );
}
