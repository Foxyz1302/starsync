import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../session/health.dart';
import '../state/session_state.dart';
import '../update/updater.dart';
import '../widgets/dialogs.dart';
import '../widgets/member_avatar.dart';
import '../widgets/shown_frame_probe.dart';
import '../widgets/text_focus.dart';
import '../widgets/window_buttons.dart';
import '../widgets/window_drag_layer.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  // One key per player generation: a reloaded player needs a fresh
  // `Video` (it never swaps controllers in place).
  var _videoGen = -1;
  var _videoKey = GlobalKey<VideoState>();
  bool _refullscreen = false;
  final _frameProbe = ShownFrameProbe();
  final _sheetOpen = signal(false);
  final _confirmLeave = signal(false);
  final _isFullscreen = signal(false);
  DateTime? _lastKeyAt;
  final _chat = TextEditingController();
  final _chatFocus = FocusNode();
  final _swapLink = TextEditingController();
  late final void Function() _stopKickWatch;
  late final void Function() _stopSheetWatch;
  late final void Function() _stopPlayerWatch;
  late final FocusNode _noFocus;

  @override
  void initState() {
    super.initState();
    final session = SessionState.instance;
    _noFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
    session.coordinator.playback.shownFrame = _frameProbe.sample;
    HardwareKeyboard.instance.addHandler(_globalKey);
    _stopKickWatch = effect(() {
      if (session.coordinator.kickReason.value != null) {
        session.route.value = AppRoute.home;
      }
    });
    _stopSheetWatch = effect(() {
      if (!_sheetOpen.value) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
    // The fullscreen route holds its own `Video` of the old player: leave
    // it before the player goes away, re-enter once the new one is up.
    _stopPlayerWatch = effect(() {
      final alive = session.coordinator.playback.alive.value;
      if (!alive && _isFullscreen.peek()) {
        _refullscreen = true;
        if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      } else if (alive && _refullscreen) {
        _refullscreen = false;
        // Entering before the new output's first frame leaves the
        // fullscreen copy blank for good (seen in a real run).
        () async {
          try {
            await session.coordinator.playback.video.waitUntilFirstFrameRendered
                .timeout(const Duration(seconds: 10));
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 100));
          if (mounted && !_isFullscreen.peek() && session.coordinator.playback.alive.peek()) {
            _videoKey.currentState?.enterFullscreen();
          }
        }();
      }
    });
  }

  void _reloadVideo() {
    final coord = SessionState.instance.coordinator;
    coord.markInput();
    coord.reloadVideo();
  }

  void _toggleFullscreen() {
    if (_isFullscreen.peek()) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    } else {
      _videoKey.currentState?.enterFullscreen();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKey);
    final playback = SessionState.instance.coordinator.playback;
    if (playback.shownFrame == _frameProbe.sample) playback.shownFrame = null;
    _stopKickWatch();
    _stopSheetWatch();
    _stopPlayerWatch();
    _chat.dispose();
    _chatFocus.dispose();
    _swapLink.dispose();
    _noFocus.dispose();
    super.dispose();
  }

  bool _globalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) return false;
    if (textInputFocused()) return false;
    final now = DateTime.now().toUtc();
    if (_lastKeyAt != null && now.difference(_lastKeyAt!).inMilliseconds < 350) {
      return false;
    }
    final coord = SessionState.instance.coordinator;
    if (event.logicalKey == LogicalKeyboardKey.keyR &&
        HardwareKeyboard.instance.isControlPressed) {
      _lastKeyAt = now;
      _reloadVideo();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _lastKeyAt = now;
      coord.toggleReady();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _lastKeyAt = now;
      _sheetOpen.value = !_sheetOpen.peek();
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
      if (_sheetOpen.peek()) {
        _sheetOpen.value = false;
        return true;
      }
      if (_confirmLeave.peek()) {
        _confirmLeave.value = false;
        return true;
      }
      if (_isFullscreen.peek()) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
        return true;
      }
      _lastKeyAt = now;
      _confirmLeave.value = true;
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _lastKeyAt = now;
      if (_isFullscreen.peek()) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
      } else {
        _videoKey.currentState?.enterFullscreen();
      }
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    final controlsTheme = MaterialDesktopVideoControlsThemeData(
      playAndPauseOnTap: false,
      modifyVolumeOnScroll: false,
      keyboardShortcuts: {},
      visibleOnMount: true,
      hideMouseOnControlsRemoval: true,
      controlsHoverDuration: const Duration(seconds: 3),
      topButtonBar: [
        const Spacer(),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.group),
          onPressed: () {
            _sheetOpen.value = true;
            coord.markInput();
          },
        ),
        SignalBuilder(
          builder: (context) => WindowButtons(focusNode: _noFocus, fullscreen: _isFullscreen.value, onToggleFullscreen: _toggleFullscreen),
        ),
      ],
      bottomButtonBar: [
        const MaterialDesktopVolumeButton(),
        _ReadyControlButton(focusNode: _noFocus),
        _MarkAllReadyControlButton(focusNode: _noFocus),
        _ReloadVideoControlButton(focusNode: _noFocus, onPressed: _reloadVideo),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ],
    );
    return FocusTraversalGroup(
      descendantsAreTraversable: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        // Player lifetime = session (and each "Reload video"): no live
        // player ⇒ no `Video`, so no texture outlives its player.
        body: SignalBuilder(
          builder: (context) {
            final playback = coord.playback;
            final gen = playback.generation.value;
            if (!playback.alive.value) {
              return const Center(
                child: Text('player starting…', style: TextStyle(color: Colors.white)),
              );
            }
            if (gen != _videoGen) {
              _videoGen = gen;
              _videoKey = GlobalKey<VideoState>();
            }
            return MaterialDesktopVideoControlsTheme(
              normal: controlsTheme,
              fullscreen: controlsTheme,
              child: Video(
                key: _videoKey,
                controller: playback.video,
                subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                controls: _sessionControls,
                onEnterFullscreen: () async {
                  _isFullscreen.value = true;
                  await defaultEnterNativeFullscreen();
                },
                onExitFullscreen: () async {
                  _isFullscreen.value = false;
                  await defaultExitNativeFullscreen();
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _sessionControls(VideoState state) {
    return Stack(
      children: [
        // Frozen-picture watchdog samples the route around this anchor.
        _frameProbe.anchor(),
        MaterialDesktopVideoControls(state),
        _healthOverlay(),
        _waitingOverlay(),
        _toastsOverlay(),
        _sheetOverlay(),
        _leaveOverlay(),
        Positioned.fill(
          child: SignalBuilder(
            builder: (context) {
              final sheetOpen = _sheetOpen.value;
              final confirm = _confirmLeave.value;
              return WindowDragLayer(
                enabled: !confirm,
                exclusions: [
                  (s) => Rect.fromLTWH(0, s.height - 120, s.width, 120),
                  if (sheetOpen) (s) => Rect.fromLTWH(s.width - 380, 0, 380, s.height),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _healthOverlay() {
    final coord = SessionState.instance.coordinator;
    return Positioned(
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
    );
  }

  Widget _waitingOverlay() {
    final coord = SessionState.instance.coordinator;
    return SignalBuilder(
      builder: (context) {
        final r = coord.room.value;
        final waiting = [
          for (final m in r?.members ?? [])
            if (!m.ready) m,
        ];
        final show = r != null && r.transport == 'held' && waiting.isNotEmpty;
        final selfReady = coord.selfMember.value?.ready ?? false;
        return Positioned.fill(
          child: Center(
            child: Visibility(
              visible: show,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: Column(
                mainAxisSize: .min,
                spacing: 12,
                children: [
                  IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadiusGeometry.circular(20)),
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
                  if (!selfReady)
                    FilledButton(
                      focusNode: _noFocus,
                      onPressed: () => coord.toggleReady(),
                      child: const Text("I'm Ready"),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _toastsOverlay() {
    final coord = SessionState.instance.coordinator;
    return Positioned(
      right: 12,
      top: 56,
      child: IgnorePointer(
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
    );
  }

  Widget _sheetOverlay() {
    return SignalBuilder(
      builder: (context) {
        final open = _sheetOpen.value;
        return ExcludeFocus(
          excluding: !open,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !open,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: open ? 1 : 0,
                    child: GestureDetector(
                      onTap: () => _sheetOpen.value = false,
                      child: Container(color: Colors.black54),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 20,
                bottom: 20,
                right: 0,
                child: IgnorePointer(
                  ignoring: !open,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    offset: open ? Offset.zero : const Offset(1, 0),
                    child: SizedBox(
                      width: 380,
                      height: double.infinity,
                      child: _SheetPanel(
                        chat: _chat,
                        chatFocus: _chatFocus,
                        swapLink: _swapLink,
                        onClose: () => _sheetOpen.value = false,
                        onLeave: () {
                          _sheetOpen.value = false;
                          _confirmLeave.value = true;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _leaveOverlay() {
    final session = SessionState.instance;
    return SignalBuilder(
      builder: (context) {
        if (!_confirmLeave.value) return const SizedBox.shrink();
        return Positioned.fill(
          child: GestureDetector(
            onTap: () => _confirmLeave.value = false,
            child: Container(
              color: Colors.black54,
              child: Center(
                child: GestureDetector(
                  onTap: () {},
                  child: AlertDialog(
                    title: const Text('Leave server?'),
                    content: const Text('You can rejoin right away.'),
                    actions: [
                      TextButton(onPressed: () => _confirmLeave.value = false, child: const Text('Cancel')),
                      TextButton(
                        onPressed: () {
                          _confirmLeave.value = false;
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
        );
      },
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

class _ReloadVideoControlButton extends StatelessWidget {
  final FocusNode focusNode;
  final VoidCallback onPressed;
  const _ReloadVideoControlButton({required this.focusNode, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Reload video (Ctrl+R) — fixes a frozen picture',
      child: TextButton.icon(
        focusNode: focusNode,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Reload video', style: TextStyle(fontSize: 12)),
      ),
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
  final FocusNode chatFocus;
  final TextEditingController swapLink;
  final VoidCallback onClose;
  final VoidCallback onLeave;
  const _SheetPanel({required this.chat, required this.chatFocus, required this.swapLink, required this.onClose, required this.onLeave});

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    return Material(
      borderRadius: BorderRadius.horizontal(left: .circular(20)),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SignalBuilder(
          builder: (context) {
            final r = coord.room.value;
            final log = coord.feedLog.value;
            final theme = Theme.of(context);
            final sectionStyle = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold);
            final members = r?.members ?? const <MemberView>[];
            final readyCount = members.where((m) => m.ready).length;
            final playing = r?.transport == 'playing';
            return Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Server', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              _StatusChip(playing: playing, hasRoom: r != null),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            r == null ? 'connecting…' : '${members.length} member${members.length == 1 ? '' : 's'} · $readyCount ready',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: onClose),
                  ],
                ),
                const Divider(height: 20),
                Text('Users (${members.length})', style: sectionStyle),
                const SizedBox(height: 2),
                for (final m in members) _MemberRow(member: m, isSelf: m.id == coord.sync.memberId),
                const Divider(height: 20),
                Text('Activity', style: sectionStyle),
                const SizedBox(height: 6),
                if (log.isEmpty) Text('No events yet', style: theme.textTheme.bodySmall),
                Expanded(
                  child: ListView.builder(
                    reverse: true,
                    itemBuilder: (context, index) => _ActivityRow(item: log.reversed.toList()[index]),
                    itemCount: log.length,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: chat,
                        focusNode: chatFocus,
                        decoration: const InputDecoration(labelText: 'Chat message', border: OutlineInputBorder(), isDense: true),
                        onSubmitted: (v) {
                          coord.sendChat(v);
                          chat.clear();
                          chatFocus.requestFocus();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () {
                        coord.sendChat(chat.text);
                        chat.clear();
                        chatFocus.requestFocus();
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
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: swapLink,
                      builder: (context, value, _) {
                        final link = value.text.trim();
                        return IconButton(
                          icon: const Icon(Icons.swap_horiz),
                          onPressed: link.isEmpty
                              ? null
                              : () {
                                  coord.swapLink(link);
                                  swapLink.clear();
                                },
                        );
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
                    label: const Text('Leave server'),
                    onPressed: onLeave,
                  ),
                ),
                const SizedBox(height: 8),
                const Center(
                  child: Text('v$appVersion', style: TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool playing;
  final bool hasRoom;
  const _StatusChip({required this.playing, required this.hasRoom});

  @override
  Widget build(BuildContext context) {
    final Color dot;
    final String label;
    if (!hasRoom) {
      dot = Colors.grey;
      label = '…';
    } else if (playing) {
      dot = Colors.green;
      label = 'Playing';
    } else {
      dot = Colors.orange;
      label = 'Waiting';
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(999)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
          ),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final MemberView member;
  final bool isSelf;
  const _MemberRow({required this.member, required this.isSelf});

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    final theme = Theme.of(context);
    final status = _memberStatus(member);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          MemberAvatar(avatarBase64: member.avatar, name: member.name, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSelf ? '${member.name} (you)' : member.name,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: status.$2),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      status.$1,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.75)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            padding: EdgeInsets.zero,
            onSelected: (v) async {
              if (v == 'force') {
                coord.forceTarget(member.id, !member.ready);
              } else if (v == 'kick') {
                final ok = await showKickConfirmDialog(context, member.name);
                if (ok == true) coord.kick(member.id);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'force', child: Text(member.ready ? 'Force unready' : 'Force ready')),
              PopupMenuItem(
                value: 'kick',
                child: Text('Kick', style: TextStyle(color: theme.colorScheme.error)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

(String, Color) _memberStatus(MemberView m) {
  if (m.stale) return ('Stale', Colors.orange);
  if (!m.ready) return ('Not ready', Colors.grey);
  if (m.buffered < RelayConstants.minBufferSecs) return ('Buffering ${m.buffered.toStringAsFixed(0)}s', Colors.orange);
  return ('Ready', Colors.green);
}

class _ActivityRow extends StatelessWidget {
  final FeedMessage item;
  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = _clock(item.at);
    final subtle = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6) ?? Colors.grey;
    if (item.action == 'chat') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 15, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${item.actor}  ',
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: item.reason, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(time, style: theme.textTheme.labelSmall?.copyWith(color: subtle)),
          ],
        ),
      );
    }
    if (item.actor == 'server') {
      final style = _serverFeedStyle(item);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(style.$1, size: 15, color: style.$2),
            const SizedBox(width: 8),
            Expanded(child: Text(style.$3, style: theme.textTheme.bodySmall)),
            const SizedBox(width: 8),
            Text(time, style: theme.textTheme.labelSmall?.copyWith(color: subtle)),
          ],
        ),
      );
    }
    final style = _feedStyle(item, theme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(style.$1, size: 15, color: style.$2),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: item.actor,
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: ' ${style.$3}', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(time, style: theme.textTheme.labelSmall?.copyWith(color: subtle)),
        ],
      ),
    );
  }
}

(IconData, Color, String) _feedStyle(FeedMessage f, ThemeData theme) {
  switch (f.action) {
    case 'join':
      return (Icons.person_add, Colors.green, 'joined');
    case 'leave':
      final reason = f.reason == 'silent too long' ? ' · timed out' : (f.reason.isEmpty ? '' : ' · ${f.reason}');
      return (Icons.logout, Colors.grey, 'left$reason');
    case 'ready':
      return (Icons.check_circle, Colors.green, 'is ready');
    case 'unready':
      return (Icons.radio_button_unchecked, Colors.grey, "isn't ready");
    case 'force-ready':
      return (Icons.how_to_reg, Colors.orange, 'marked ${f.target ?? ''} ready');
    case 'force-unready':
      return (Icons.how_to_reg, Colors.orange, 'marked ${f.target ?? ''} not ready');
    case 'force-play':
      return (Icons.play_arrow, Colors.green, 'started playback for everyone');
    case 'force-hold':
      return (Icons.pause, Colors.orange, 'held playback for everyone');
    case 'seek':
      return (Icons.fast_forward, theme.colorScheme.primary, 'seeked');
    case 'swap':
      return (Icons.movie, theme.colorScheme.primary, 'changed the media');
    case 'stale':
      return (Icons.cloud_off, Colors.orange, 'lost signal');
    case 'kick':
      final reason = f.reason.isEmpty ? '' : ' · ${f.reason}';
      return (Icons.gavel, Colors.red, 'kicked ${f.target ?? ''}$reason');
    default:
      final target = f.target == null || f.target!.isEmpty ? '' : ' ${f.target}';
      return (Icons.info_outline, Colors.grey, '${f.action}$target');
  }
}

(IconData, Color, String) _serverFeedStyle(FeedMessage f) {
  switch (f.action) {
    case 'resume':
      return (Icons.play_arrow, Colors.green, 'Playback resumed');
    default:
      return (Icons.pause, Colors.orange, 'Playback paused · waiting for readiness');
  }
}

String _clock(DateTime at) {
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}
