import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../session/health.dart';
import '../session/party.dart';
import '../session/session_coordinator.dart';
import '../state/session_state.dart';
import '../widgets/app_menu.dart' show AppGlass;
import 'avatar.dart';
import 'motion.dart';

/// What the player's status pill says, most pressing first.
enum StatusKind { reconnecting, problem, connecting, finished, loading, you, cannotPlay, waiting }

/// The pill's button: stop reconnecting, retry (reconnect), reload the
/// video (your player could not open it), or mark yourself ready (the
/// whole pill).
enum StatusAction { cancel, retry, reload, ready }

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
/// connecting has taken over 2 s. [playerError]: why your player cannot
/// open the media (the coordinator's `playerError`).
StatusView? playerStatusFor({
  required HealthStatus health,
  bool reconnecting = false,
  bool unstable = false,
  StateBroadcast? state,
  MemberView? self,
  bool slowConnect = false,
  String playerError = '',
}) {
  if (reconnecting) {
    return const StatusView(StatusKind.reconnecting, 'Reconnecting…',
        tone: HealthSeverity.warn, action: StatusAction.cancel);
  }
  if (unstable) {
    return const StatusView(StatusKind.reconnecting, 'Connection unstable…', tone: HealthSeverity.warn);
  }
  final away = self?.presence == Presence.away;
  if (playerError.isNotEmpty && state?.media != null && !away) {
    return StatusView(StatusKind.problem, "Can't play this: $playerError",
        tone: HealthSeverity.error, action: StatusAction.reload, short: "Can't play this");
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
  // Sitting out: the join-back card says it; nobody waits for you.
  if (away) return null;
  if (r.transport == 'finished') {
    return const StatusView(StatusKind.finished, 'Finished · seek back or pick the next video', short: 'Finished');
  }
  // Members whose player cannot open it: the server does not wait for
  // them; say why instead of "waiting for".
  final failed = [
    for (final m in r.members)
      if (m.error.isNotEmpty && isPresent(m) && (self == null || m.id != self.id)) m,
  ];
  // As the server holds playback: someone in the ready set short of the
  // minimum buffer.
  final need = r.bufferNeed;
  for (final m in r.members) {
    if (m.inSet && m.buffered < need) {
      final you = self != null && m.id == self.id;
      final p = (m.buffered / need).clamp(0.0, 1.0);
      return StatusView(StatusKind.loading, you ? 'Loading the video…' : '${m.name} is loading…',
          who: [m], self: you, progress: p, detail: '${(p * 100).round()}%');
    }
  }
  if (failed.isNotEmpty) {
    final f = failed.first;
    final who = nameList([for (final m in failed) m.name]);
    final unready = self != null && !self.ready;
    return StatusView(StatusKind.cannotPlay, "$who can't play this: ${f.error}",
        who: failed,
        short: "$who can't play this",
        detail: unready ? "Press Space when you're ready" : null,
        action: unready ? StatusAction.ready : null);
  }
  if (self != null && !self.ready) {
    return StatusView(StatusKind.you, "Press Space when you're ready",
        who: [self], self: true, action: StatusAction.ready, detail: 'or click here', short: 'Press Space when ready');
  }
  // Members sitting out or gone are never waited for nor counted.
  final active = [for (final m in r.members) if (countsForReady(m)) m];
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
    unstable: c.unstable.value,
    state: c.serverState.value,
    self: c.selfMember.value,
    slowConnect: slowConnect,
    playerError: c.playerError.value,
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
      case StatusAction.reload:
        unawaited(coord.reloadVideo());
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

/// The player's pill surface (the status pill, the action pills, the
/// unread chip): the app's glass as a stadium ([AppGlass.pill]).
class PlayerGlass extends StatelessWidget {
  final Widget child;
  const PlayerGlass({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AppGlass.pill(child: child),
      );
}

class _StatusLine extends StatelessWidget {
  final StatusView view;
  final SessionCoordinator coord;
  final ValueChanged<StatusAction> onAction;
  const _StatusLine({super.key, required this.view, required this.coord, required this.onAction});

  static const _avatar = 34.0;

  Widget? _lead() {
    final v = view;
    switch (v.kind) {
      case StatusKind.problem:
        final error = v.tone == HealthSeverity.error;
        return Icon(error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            size: 20, color: error ? Colors.redAccent.shade100 : Colors.amber);
      case StatusKind.reconnecting:
        return const _Spinner(color: Colors.amber);
      case StatusKind.connecting:
        return const _Spinner(color: Colors.white70);
      case StatusKind.finished:
        return null;
      case StatusKind.loading:
      case StatusKind.you:
      case StatusKind.cannotPlay:
      case StatusKind.waiting:
        final r = coord.serverState.value;
        final infos = [
          for (final m in v.who)
            v.self ? selfAvatarInfo(ready: m.ready, host: m.host) : memberAvatarInfo(m, r, coord),
        ];
        if (infos.isEmpty) return null;
        final avatar = infos.length == 1
            ? StatusAvatar(info: infos.first, size: _avatar, badges: false)
            : AvatarStack(members: infos, shown: 4, size: _avatar);
        if (v.progress == null) return avatar;
        // Loading: the progress runs round the avatar.
        return Stack(
          alignment: Alignment.center,
          children: [
            avatar,
            SizedBox.square(
              dimension: _avatar + 6,
              child: CircularProgressIndicator(
                value: v.progress,
                strokeWidth: 2.5,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = view;
    final lead = _lead();
    final avatars = v.who.isNotEmpty;
    final action = v.action == StatusAction.ready ? null : v.action;
    return Padding(
      padding: EdgeInsets.fromLTRB(lead == null ? 18 : (avatars ? 5 : 14), 5, action == null ? 18 : 6, 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead != null) ...[
            SizedBox(height: _avatar + 6, child: Center(child: lead)),
            SizedBox(width: avatars ? 10 : 8),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _avatar),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.text,
                    key: const ValueKey('player-status-text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.2),
                  ),
                  if (v.detail != null)
                    Text(
                      v.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500, height: 1.2),
                    ),
                ],
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
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
