import 'dart:async';

import 'package:flutter/material.dart';

import '../session/session_coordinator.dart';
import '../app/app_graph.dart';
import '../widgets/app_menu.dart' show AppGlass;
import 'avatar.dart';
import 'motion.dart';

export '../session/status.dart' show StatusAction, StatusKind, StatusLevel, StatusLine, nameList;

/// The pill's line from the session's [SessionCoordinator.status]
/// (tracked: call inside a builder); "Connecting…" only once it has taken
/// [PlayerStatus.connectGrace] ([slowConnect]).
StatusLine? playerStatusNow(SessionCoordinator coord, {bool slowConnect = false}) {
  final line = coord.status.value.line;
  if (line?.kind == StatusKind.connecting && !slowConnect) return null;
  return line;
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
  StatusLine? _last;

  @override
  void dispose() {
    _connectTimer?.cancel();
    super.dispose();
  }

  // "Connecting…" only once it takes a while.
  void _trackConnecting(StatusLine? line) {
    final connecting = line?.kind == StatusKind.connecting;
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
      final coord = AppScope.of(context).coordinator;
      _trackConnecting(coord.status.value.line);
      final view = playerStatusNow(coord, slowConnect: _slow);
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
  final StatusLine view;
  final SessionCoordinator coord;
  final ValueChanged<StatusAction> onAction;
  const _StatusLine({super.key, required this.view, required this.coord, required this.onAction});

  static const _avatar = 34.0;

  Widget? _lead() {
    final v = view;
    switch (v.kind) {
      case StatusKind.problem:
        final error = v.level == StatusLevel.error;
        return Icon(error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            size: 20, color: error ? Colors.redAccent.shade100 : Colors.amber);
      case StatusKind.reconnecting:
        return const _Spinner(color: Colors.amber);
      case StatusKind.connecting:
      case StatusKind.fetching:
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
