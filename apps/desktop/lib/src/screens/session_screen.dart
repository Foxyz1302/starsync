import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../session/health.dart';
import '../state/session_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/member_avatar.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  VideoController? _video;
  bool _sheetOpen = false;
  bool _confirmLeave = false;
  DateTime? _lastKeyAt;
  final _chat = TextEditingController();
  final _swapLink = TextEditingController();
  late final void Function() _stopKickWatch;
  late final FocusNode _noFocus;

  @override
  void initState() {
    super.initState();
    final session = SessionState.instance;
    _noFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
    _video = VideoController(session.coordinator.playback.player);
    HardwareKeyboard.instance.addHandler(_globalKey);
    _stopKickWatch = effect(() {
      if (session.coordinator.kickReason.value != null) {
        session.route.value = AppRoute.connect;
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKey);
    _stopKickWatch();
    _chat.dispose();
    _swapLink.dispose();
    _noFocus.dispose();
    super.dispose();
  }

  bool get _editing {
    var n = FocusManager.instance.primaryFocus;
    while (n != null) {
      final w = n.context?.widget;
      if (w is EditableText) return true;
      n = n.parent;
    }
    return false;
  }

  bool _globalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) return false;
    if (_editing) return false;
    final now = DateTime.now().toUtc();
    if (_lastKeyAt != null && now.difference(_lastKeyAt!).inMilliseconds < 350) {
      return false;
    }
    final coord = SessionState.instance.coordinator;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _lastKeyAt = now;
      coord.toggleReady();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (!mounted) return false;
      _lastKeyAt = now;
      setState(() => _sheetOpen = !_sheetOpen);
      coord.markInput();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _lastKeyAt = now;
      coord.nudge(10);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _lastKeyAt = now;
      coord.nudge(-10);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!mounted) return false;
      if (_sheetOpen) {
        setState(() => _sheetOpen = false);
        return true;
      }
      _lastKeyAt = now;
      setState(() => _confirmLeave = true);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    final coord = session.coordinator;
    final controlsTheme = MaterialDesktopVideoControlsThemeData(
      playAndPauseOnTap: false,
      keyboardShortcuts: {},
      visibleOnMount: true,
      hideMouseOnControlsRemoval: false,
      controlsHoverDuration: const Duration(hours: 24),
      bottomButtonBar: [
        const MaterialDesktopVolumeButton(),
        _ReadyControlButton(focusNode: _noFocus),
        _MarkAllReadyControlButton(focusNode: _noFocus),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ],
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _video == null
                ? const Center(
                    child: Text('player starting…', style: TextStyle(color: Colors.white)),
                  )
                : MaterialDesktopVideoControlsTheme(
                    normal: controlsTheme,
                    fullscreen: controlsTheme,
                    child: Video(controller: _video!),
                  ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.group, color: Colors.white),
                    onPressed: () {
                      setState(() => _sheetOpen = !_sheetOpen);
                      coord.markInput();
                    },
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: SignalBuilder(
              builder: (context) {
                final h = coord.health.value;
                final starve = coord.starving.value;
                final retrying = coord.reconnecting.value;
                final kicked = coord.kickReason.value;
                final unwell = h.severity == HealthSeverity.warn || h.severity == HealthSeverity.error || retrying || starve != null;
                if (!unwell) return const SizedBox.shrink();
                final color = switch (h.severity) {
                  HealthSeverity.ok => Colors.green,
                  HealthSeverity.info => Colors.grey,
                  HealthSeverity.warn => Colors.orange,
                  HealthSeverity.error => Colors.red,
                };
                final IconData icon;
                if (retrying) {
                  icon = Icons.sync;
                } else if (h.severity == HealthSeverity.error) {
                  icon = Icons.error_outline;
                } else if (h.severity == HealthSeverity.warn) {
                  icon = Icons.warning_amber_outlined;
                } else {
                  icon = Icons.hourglass_empty;
                }
                final text = [h.message, if (starve != null) starve, if (retrying) 'reconnecting…'].join(' · ');
                final canRetry = !retrying && kicked == null && (h.severity == HealthSeverity.error || h.severity == HealthSeverity.warn);
                return Container(
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(999)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: color, size: 16),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                      if (retrying)
                        TextButton(
                          style: TextButton.styleFrom(foregroundColor: Colors.white, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          onPressed: () => coord.cancelReconnect(),
                          child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                        ),
                      if (canRetry)
                        TextButton(
                          style: TextButton.styleFrom(foregroundColor: Colors.white, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          onPressed: () => coord.retry(),
                          child: const Text('Retry', style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          SignalBuilder(
            builder: (context) {
              final r = coord.room.value;
              final waiting = [
                for (final m in r?.members ?? [])
                  if (!m.ready) m,
              ];
              final show = r != null && r.transport == 'held' && waiting.isNotEmpty;
              return Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Visibility(
                      visible: show,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadiusGeometry.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            mainAxisSize: .min,
                            spacing: 10,
                            crossAxisAlignment: .center,
                            children: [
                              Text("Waiting for", style: TextTheme.of(context).labelLarge),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: -20,
                                runSpacing: 8,
                                children: [
                                  for (final m in waiting)
                                    Opacity(
                                      opacity: m.stale ? 0.5 : 1.0,
                                      child: MemberAvatar(avatarBase64: m.avatar, name: m.name, size: 96),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            right: 12,
            top: 56,
            child: SignalBuilder(
              builder: (context) {
                final items = coord.toasts.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [for (final t in items.reversed.take(5)) _ToastCard(key: ValueKey(t.id), text: t.text)],
                );
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_sheetOpen,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _sheetOpen ? 1 : 0,
                child: GestureDetector(
                  onTap: () => setState(() => _sheetOpen = false),
                  child: Container(color: Colors.black54),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_sheetOpen,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                offset: _sheetOpen ? Offset.zero : const Offset(1, 0),
                child: SizedBox(
                  width: 380,
                  height: double.infinity,
                  child: _SheetPanel(
                    chat: _chat,
                    swapLink: _swapLink,
                    onClose: () => setState(() => _sheetOpen = false),
                    onLeave: () => setState(() {
                      _sheetOpen = false;
                      _confirmLeave = true;
                    }),
                  ),
                ),
              ),
            ),
          ),
          if (_confirmLeave)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _confirmLeave = false),
                child: Container(
                  color: Colors.black54,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {},
                      child: AlertDialog(
                        title: const Text('Leave room?'),
                        content: const Text('You can rejoin right away.'),
                        actions: [
                          TextButton(onPressed: () => setState(() => _confirmLeave = false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () {
                              setState(() => _confirmLeave = false);
                              session.leave();
                            },
                            child: const Text('Leave'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReadyControlButton extends StatelessWidget {
  final FocusNode focusNode;
  const _ReadyControlButton({required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final ready = SessionState.instance.coordinator.selfMember.value?.ready ?? false;
        return TextButton(
          focusNode: focusNode,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => SessionState.instance.coordinator.toggleReady(),
          child: Text(ready ? 'Ready ✓' : 'Not ready', style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }
}

class _MarkAllReadyControlButton extends StatelessWidget {
  final FocusNode focusNode;
  const _MarkAllReadyControlButton({required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      focusNode: focusNode,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => SessionState.instance.coordinator.forcePlayAll(),
      child: const Text('Mark everyone ready', style: TextStyle(fontSize: 12)),
    );
  }
}

class _ToastCard extends StatefulWidget {
  final String text;
  const _ToastCard({super.key, required this.text});

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      offset: _shown ? Offset.zero : const Offset(1, 0),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _shown ? 1 : 0,
        child: Card(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text(widget.text)),
        ),
      ),
    );
  }
}

class _SheetPanel extends StatelessWidget {
  final TextEditingController chat;
  final TextEditingController swapLink;
  final VoidCallback onClose;
  final VoidCallback onLeave;
  const _SheetPanel({required this.chat, required this.swapLink, required this.onClose, required this.onLeave});

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    final coord = session.coordinator;
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SignalBuilder(
          builder: (context) {
            final r = coord.room.value;
            final log = coord.feedLog.value;
            final theme = Theme.of(context);
            final sectionStyle = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold);
            return ListView(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Room', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(
                            'transport ${r?.transport ?? '…'} · event ${r?.eventId ?? 0} · media ${r?.mediaId ?? 0}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: onClose),
                  ],
                ),
                const Divider(height: 20),
                Text('Users (${r?.members.length ?? 0})', style: sectionStyle),
                const SizedBox(height: 6),
                if (r != null)
                  for (final m in r.members)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        dense: true,
                        leading: MemberAvatar(avatarBase64: m.avatar, name: m.name, size: 36),
                        title: Text(m.id == coord.sync.memberId ? '${m.name} (you)' : m.name),
                        subtitle: Text('ready=${m.ready} inSet=${m.inSet} buf=${m.buffered.toStringAsFixed(1)} stale=${m.stale}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => coord.forceTarget(m.id, !m.ready),
                              child: Text(m.ready ? 'Force unready' : 'Force ready'),
                            ),
                            TextButton(
                              onPressed: () async {
                                final ok = await showKickConfirmDialog(context, m.name);
                                if (ok == true) coord.kick(m.id);
                              },
                              child: const Text('Kick'),
                            ),
                          ],
                        ),
                      ),
                    ),
                const Divider(height: 20),
                Text('Log', style: sectionStyle),
                const SizedBox(height: 6),
                if (log.isEmpty) Text('No events yet', style: theme.textTheme.bodySmall),
                for (final f in log.reversed.take(30))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('${f.actor} ${f.action} ${f.target ?? ''}', style: theme.textTheme.bodySmall),
                  ),
                const Divider(height: 20),
                Text('Chat', style: sectionStyle),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: chat,
                        decoration: const InputDecoration(labelText: 'Chat message', border: OutlineInputBorder(), isDense: true),
                        onSubmitted: (v) {
                          coord.sendChat(v);
                          chat.clear();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () {
                        coord.sendChat(chat.text);
                        chat.clear();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Share a link', style: sectionStyle),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: swapLink,
                        decoration: const InputDecoration(labelText: 'Swap to link URL', border: OutlineInputBorder(), isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.swap_horiz),
                      onPressed: () {
                        coord.swapLink(swapLink.text.trim());
                        swapLink.clear();
                      },
                    ),
                  ],
                ),
                const Divider(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    icon: const Icon(Icons.logout),
                    label: const Text('Leave room'),
                    onPressed: onLeave,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
