import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../controls/controls_probe.dart';
import '../controls/model/controls_model.dart';
import '../controls/session_controls.dart';
import '../controls/volume.dart';
import '../queue/queue_ui.dart';
import '../playback/media_marks.dart' show SkipKind, SkipOffer, formatClock;
import '../screens/session/jellyfin_widgets.dart';
import '../screens/session/player_controls.dart';
import '../session/session_coordinator.dart';
import '../shaders/shader_presets.dart';
import '../state/session_state.dart';
import '../state/settings.dart';
import '../widgets/app_keys.dart';
import '../widgets/text_focus.dart';
import '../widgets/window_buttons.dart';
import 'avatar.dart';
import 'motion.dart';
import 'now_playing_title.dart';
import 'player_status.dart';
import 'sit_out_card.dart';
import 'start_banner.dart';

/// Where the session's video is shown: nowhere, the floating mini player,
/// or filling the body (and, with fullscreen, the window).
enum PlayerMode { none, mini, full }

/// Builds the one video view of the current player around [controls]
/// (null: none, the mini player). Tests pass a stand-in: media_kit's
/// `Video` hangs flutter_test.
typedef VideoViewBuilder = Widget Function(BuildContext context, VideoControlsBuilder? controls);

/// The session's player: the one `Video` of the current player and
/// everything over it. Full: the controls (one model, the skin picked in
/// Settings), the start card, the status pill, Jellyfin overlays and
/// the player keys. Mini: hover controls and a progress line. The shell keeps this
/// widget mounted at one place in the tree while the mode changes, so the
/// `Video` is never mounted twice nor rebuilt for a move.
class SessionPlayer extends StatefulWidget {
  final PlayerMode mode;
  final bool fullscreen;
  final bool chatOpen;
  final int unread;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleChat;
  final VoidCallback onChangeVideo;
  final VoidCallback onOpenIntegrations;
  /// Asks before leaving the server.
  final VoidCallback onLeave;
  final VideoViewBuilder? videoBuilder;
  /// Window buttons in the fullscreen top bar (off in tests: they need
  /// window_manager).
  final bool windowControls;
  const SessionPlayer({
    super.key,
    required this.mode,
    required this.fullscreen,
    required this.onExpand,
    required this.onCollapse,
    required this.onClose,
    required this.onToggleFullscreen,
    required this.onToggleChat,
    required this.onChangeVideo,
    required this.onOpenIntegrations,
    required this.onLeave,
    this.chatOpen = false,
    this.unread = 0,
    this.videoBuilder,
    this.windowControls = true,
  });

  @override
  State<SessionPlayer> createState() => _SessionPlayerState();
}

class _SessionPlayerState extends State<SessionPlayer> {
  // One key per player generation: a reloaded player needs a fresh
  // `Video` (it never swaps controllers in place).
  var _videoGen = -1;
  var _videoKey = GlobalKey<VideoState>();
  final _noFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  DateTime? _lastKeyAt;
  late final void Function() _stopShaderWatch;
  // Own toast ids, negative: the coordinator counts up from 1.
  int _toastSeq = 0;
  int _shaderNoticeSeen = 0;
  bool _miniHover = false;
  // Whether the controls are up (their frame reports it).
  final _controlsShown = ValueNotifier(true);
  // The mouse on a floating element, or the Up next popover open, keeps
  // the controls up.
  final _hold = ControlsHold();
  late final void Function() _stopPopoverWatch;
  // The shell's state the controls show, as signals for the model.
  late final _fullscreen = signal(widget.fullscreen);
  late final _chatOpen = signal(widget.chatOpen);
  late final _unread = signal(widget.unread);
  late final PlayerControlsModel _model = PlayerControlsModel(
    coord: _coord,
    fullscreen: _fullscreen,
    chatOpen: _chatOpen,
    unread: _unread,
    onToggleFullscreen: () => widget.onToggleFullscreen(),
    onToggleChat: () => widget.onToggleChat(),
    onChangeVideo: () => widget.onChangeVideo(),
    onCollapse: () => widget.onCollapse(),
    onLeave: () => widget.onLeave(),
  );

  SessionCoordinator get _coord => SessionState.instance.coordinator;
  bool get _full => widget.mode == PlayerMode.full;

  @override
  void initState() {
    super.initState();
    _coord.jellyfin.ensureLoaded();
    HardwareKeyboard.instance.addHandler(_globalKey);
    // Tab (AppKeys) reaches the chat through here in fullscreen.
    AppKeys.addChatToggle(_toggleChat);
    // Shader messages (preset changes, load failures) become toasts.
    _shaderNoticeSeen = _coord.playback.shaderNotice.peek()?.id ?? 0;
    _stopShaderWatch = effect(() {
      final n = _coord.playback.shaderNotice.value;
      if (n == null || n.id == _shaderNoticeSeen) return;
      _shaderNoticeSeen = n.id;
      _toast(n.text);
    });
    _stopPopoverWatch = effect(() {
      _hold.set(#upNextPopover, _coord.queue.popoverOpen.value);
    });
  }

  @override
  void didUpdateWidget(SessionPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _fullscreen.value = widget.fullscreen;
    _chatOpen.value = widget.chatOpen;
    _unread.value = widget.unread;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKey);
    AppKeys.removeChatToggle(_toggleChat);
    _stopShaderWatch();
    _stopPopoverWatch();
    _noFocus.dispose();
    _controlsShown.dispose();
    _hold.dispose();
    _model.dispose();
    super.dispose();
  }

  void _toast(String text) {
    _coord.toasts.value = [
      ..._coord.toasts.peek(),
      ToastItem(id: --_toastSeq, text: text, at: DateTime.now().toUtc()),
    ];
  }

  void _toggleChat() => _model.toggleChat();

  /// The player keys, while the player fills the body and nothing (a
  /// dialog, a card, a text field) is in front of it. Space and Tab are
  /// app-wide ([AppKeys]).
  bool _globalKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) return false;
    // Mini: Esc is the last step out, asking to leave the server.
    if (!_full) {
      if (event.logicalKey != LogicalKeyboardKey.escape) return false;
      if (ModalRoute.of(context)?.isCurrent == false || textInputFocused()) return false;
      widget.onLeave();
      return true;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      // A menu of ours is open: Esc closes it.
      if (_model.menusOpen > 0 && event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.of(context, rootNavigator: true).maybePop();
        return true;
      }
      return false;
    }
    if (textInputFocused()) return false;
    final now = DateTime.now().toUtc();
    if (_lastKeyAt != null && now.difference(_lastKeyAt!).inMilliseconds < 350) {
      return false;
    }
    final model = _model;
    final key = event.logicalKey;
    // Ctrl+0..6: Anime4K's own mpv keys (off, modes A..C+A).
    final digit = _shaderKeys.indexOf(key);
    if (digit >= 0 && HardwareKeyboard.instance.isControlPressed) {
      _lastKeyAt = now;
      model.pickShader(digit == 0 ? ShaderPreset.off : ShaderPreset.modes[digit - 1], null);
      return true;
    }
    if (key == LogicalKeyboardKey.keyR && HardwareKeyboard.instance.isControlPressed) {
      _lastKeyAt = now;
      model.reload();
      return true;
    }
    // mpv's playlist keys (< >) and Shift+P / Shift+N: Jellyfin episodes.
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.character == '>' || (shift && key == LogicalKeyboardKey.keyN)) {
      // Up next first, then the next episode.
      if (!model.next()) return false;
      _lastKeyAt = now;
      return true;
    }
    if (event.character == '<' || (shift && key == LogicalKeyboardKey.keyP)) {
      if (!model.previous()) return false;
      _lastKeyAt = now;
      return true;
    }
    // mpv's chapter keys.
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.pageUp) {
      _lastKeyAt = now;
      return model.stepChapter(key == LogicalKeyboardKey.pageDown ? 1 : -1);
    }
    if (shift && key == LogicalKeyboardKey.arrowRight) {
      _lastKeyAt = now;
      model.skipForward();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      model.stepVolume(key == LogicalKeyboardKey.arrowUp ? 1 : -1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _lastKeyAt = now;
      model.nudge(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _lastKeyAt = now;
      model.nudge(-10);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      _lastKeyAt = now;
      if (widget.chatOpen) {
        widget.onToggleChat();
      } else if (widget.fullscreen) {
        widget.onToggleFullscreen();
      } else {
        // One step at a time: big player → mini, then (from mini) leave.
        widget.onCollapse();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _lastKeyAt = now;
      widget.onToggleFullscreen();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      descendantsAreTraversable: false,
      child: ColoredBox(
        color: Colors.black,
        // Player lifetime = session (and each "Reload video"): no live
        // player ⇒ no `Video`, so no texture outlives its player.
        child: SignalBuilder(builder: (context) {
          final playback = _coord.playback;
          final gen = playback.generation.value;
          if (!playback.alive.value) {
            return Center(
              child: Text('player starting…',
                  style: TextStyle(color: Colors.white70, fontSize: _full ? 14 : 12)),
            );
          }
          if (gen != _videoGen) {
            _videoGen = gen;
            _videoKey = GlobalKey<VideoState>();
          }
          final VideoControlsBuilder? controls = _full ? _sessionControls : null;
          final video = widget.videoBuilder?.call(context, controls) ?? _video(controls);
          // The wheel anywhere on the full player steps the volume
          // (lists, menus and popovers under the mouse scroll instead).
          return VolumeWheel(
            enabled: _full,
            onStep: _model.stepVolume,
            child: Stack(
              fit: StackFit.expand,
              children: [
                video,
                if (_full) ...[
                  _blockedCard(),
                  _actionArea(),
                  if (widget.fullscreen) ...[if (!SessionState.instance.solo.value) _pausedParty(), _unreadChip()],
                  _volumeReadout(),
                ] else
                  _miniOverlay(),
                // Sitting out: nothing is loaded; the card covers the
                // empty player (which stays mounted for joining back).
                if (_coord.selfOut.value) _sitOut(),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _video(VideoControlsBuilder? controls) => Video(
        key: _videoKey,
        controller: _coord.playback.video,
        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
        controls: controls,
      );

  /// Fullscreen hides the strip and its window buttons: the top bar
  /// carries them while the controls are up (restore leaves fullscreen).
  Widget? _fullscreenWindowButtons() {
    if (!widget.fullscreen || !widget.windowControls) return null;
    return Padding(
      key: const ValueKey('fullscreen-window-buttons'),
      padding: const EdgeInsets.only(left: 8),
      child: IconTheme.merge(
        data: const IconThemeData(color: Colors.white),
        child: WindowButtons(
          focusNode: _noFocus,
          fullscreen: true,
          onToggleFullscreen: widget.onToggleFullscreen,
        ),
      ),
    );
  }

  Widget _sessionControls(VideoState state) {
    // The start card sits under the controls (they stay usable on it).
    return Stack(
      fit: StackFit.expand,
      children: [
        const StartBanner(),
        SessionControls(
          model: _model,
          shown: _controlsShown,
          hold: _hold,
          onDoubleClick: widget.onToggleFullscreen,
          windowButtons: _fullscreenWindowButtons(),
        ),
      ],
    );
  }

  /// The side inset every floating element keeps (the bars' own), and
  /// the gap between them and the controls.
  static const _edge = 16.0;

  /// The bottom controls' height in the skin and size in use.
  static double _bottomControlsHeight() {
    final s = AppSettings.instance;
    return controlsBottomHeight(s.controlsSkin.value, s.controlsSize.value);
  }

  static double get _topBarHeight => controlsTopHeight(AppSettings.instance.controlsSkin.peek());

  /// The volume flash after a wheel or key step: a pill under the top bar.
  Widget _volumeReadout() => Positioned(
        left: 0,
        right: 0,
        top: _topBarHeight + 8,
        child: Center(
          child: VolumeFlash(
            trigger: _model.volumeFlash,
            builder: (context) => SignalBuilder(builder: (context) => VolumeReadout(volume: _model.volume.value)),
          ),
        ),
      );

  /// The action area: one band above the bottom controls for everything
  /// that floats there. The status pill (the ready prompt among it)
  /// centred; at the right edge the end cards, else the action pills
  /// (Skip OP / ED / 1:30 over Next episode). It rides on the controls:
  /// just above them while they are up, down near the edge while they are
  /// hidden. The mouse on any of it counts as the mouse on the controls
  /// ([ControlsHold]).
  Widget _actionArea() {
    return SignalBuilder(builder: (context) {
      final controls = _bottomControlsHeight();
      return ValueListenableBuilder<bool>(
        valueListenable: _controlsShown,
        builder: (context, shown, child) => AnimatedPositioned(
          duration: easeTime,
          curve: ease,
          left: _edge,
          right: _edge,
          top: 0,
          bottom: shown ? controls + _edge : _edge,
          child: child!,
        ),
        child: CustomMultiChildLayout(
          delegate: _ActionAreaLayout(gap: _edge),
          children: [
            LayoutId(id: _ActionSlot.status, child: ControlsHoldRegion(hold: _hold, child: const PlayerStatus())),
            LayoutId(id: _ActionSlot.side, child: _actionSide()),
          ],
        ),
      );
    });
  }

  /// The action area's right end: the end-of-media card (Up next, else the
  /// next episode; it stays up), else the pills, shown only with the
  /// controls ([PillGate]).
  Widget _actionSide() {
    final coord = _coord;
    return SignalBuilder(
      builder: (context) {
        final next = coord.nextEpisode.value;
        final countdown = coord.autoAdvance.value;
        // Up next goes before the next episode.
        final upNext = coord.queue.countdown.value;
        final finished = coord.serverState.value?.transport == 'finished';
        final pill = coord.nextPromptVisible.value;
        final SkipOffer? skip = coord.skipOffer.value;
        final showNext = next != null && pill;
        if (upNext != null && finished) {
          return ControlsHoldRegion(hold: _hold, child: UpNextCard(queue: coord.queue, countdown: upNext));
        }
        // "Clear" in Up next hides the next episode for this media.
        if (next != null && (finished || countdown != null) && coord.queue.shownContinuation.value.isNotEmpty) {
          return ControlsHoldRegion(
            hold: _hold,
            child: EndOfEpisodeCard(
              next: next,
              countdown: countdown,
              onPlayNow: coord.playNextEpisode,
              onCancel: coord.cancelAutoAdvance,
            ),
          );
        }
        if (!showNext && skip == null) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          spacing: 8,
          children: [
            if (skip != null)
              PillGate(
                key: const ValueKey('skip-gate'),
                kind: skip.kind,
                // Skip ED: no announcing, only with the controls.
                announce: skip.kind != SkipKind.ending,
                controlsShown: _controlsShown,
                hold: _hold,
                child: SkipPill(offer: skip, onPressed: () => _model.skip(skip)),
              ),
            if (showNext)
              PillGate(
                key: const ValueKey('next-gate'),
                kind: next,
                controlsShown: _controlsShown,
                hold: _hold,
                child: NextEpisodePill(episode: next, onPressed: coord.playNextEpisode),
              ),
          ],
        );
      },
    );
  }

  /// Jellyfin refused this viewer: the card in the middle (it stays up).
  Widget _blockedCard() => Positioned.fill(
        child: SignalBuilder(builder: (context) {
          final blocked = _coord.jellyfinBlocked.value;
          if (blocked == null) return const SizedBox.shrink();
          return Center(
            child: ControlsHoldRegion(
              hold: _hold,
              child: JellyfinBlockedCard(
                blocked: blocked,
                onLinkAccount: widget.onOpenIntegrations,
                onRetry: _coord.retryJellyfin,
              ),
            ),
          );
        }),
      );

  /// Fullscreen hides the strip: while paused the party stays in a corner.
  Widget _pausedParty() => Positioned(
        right: _edge,
        top: _topBarHeight + 8,
        child: PartyWatch(builder: (context) {
          final r = _coord.serverState.value;
          final paused = r != null && r.transport != 'playing';
          return AnimatedOpacity(
            duration: easeTime,
            curve: ease,
            opacity: paused ? 1 : 0,
            child: IgnorePointer(child: AvatarStack(members: partyAvatars(_coord))),
          );
        }),
      );

  /// Fullscreen hides the strip and its chat badge: while there is unread
  /// chat, the controls are down and the video is not playing, a small
  /// glass chip says so top right (while it plays, only the controls' chat
  /// button shows the count: nothing sits on the picture).
  Widget _unreadChip() => Positioned(
        right: _edge,
        top: _edge,
        child: IgnorePointer(
          child: ValueListenableBuilder<bool>(
            valueListenable: _controlsShown,
            builder: (context, shown, _) => SignalBuilder(builder: (context) {
              final playing = _coord.serverState.value?.transport == 'playing';
              final on = widget.unread > 0 && !widget.chatOpen && !shown && !playing;
              return AnimatedOpacity(
                duration: easeTime,
                curve: ease,
                opacity: on ? 1 : 0,
                child: PlayerGlass(
                  key: const ValueKey('unread-chip'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.chat_bubble_rounded, size: 14, color: Colors.white70),
                        const SizedBox(width: 6),
                        Text('${widget.unread}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );

  /// [SitOutCard] with the mini's (or the full player's) expand /
  /// collapse and close.
  Widget _sitOut() => Positioned.fill(
        child: Stack(
          fit: StackFit.expand,
          children: [
            SitOutCard(key: const ValueKey('sit-out-card'), compact: !_full),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    focusNode: _noFocus,
                    onPressed: _full ? widget.onCollapse : widget.onExpand,
                    tooltip: _full ? 'Small player' : 'Expand',
                    icon: Icon(_full ? Icons.close_fullscreen : Icons.open_in_full, color: Colors.white, size: 18),
                  ),
                  IconButton(
                    focusNode: _noFocus,
                    onPressed: widget.onClose,
                    tooltip: 'Close the player',
                    icon: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  /// Mini: title, expand and close on hover; ready, time and a seekable
  /// bar at the bottom. A thin progress line stays while not hovered.
  Widget _miniOverlay() {
    final coord = _coord;
    final playback = coord.playback;
    return MouseRegion(
      onEnter: (_) => setState(() => _miniHover = true),
      onExit: (_) => setState(() => _miniHover = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: _miniHover ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_miniHover,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent, Colors.black87],
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 10),
                        const Expanded(child: NowPlayingTitle(cover: false, compact: true)),
                        IconButton(
                          focusNode: _noFocus,
                          onPressed: widget.onExpand,
                          tooltip: 'Expand',
                          icon: const Icon(Icons.open_in_full, color: Colors.white, size: 18),
                        ),
                        IconButton(
                          focusNode: _noFocus,
                          onPressed: widget.onClose,
                          tooltip: 'Sit out (stay in the server)',
                          icon: const Icon(Icons.close, color: Colors.white, size: 18),
                        ),
                      ],
                    ),
                    const Spacer(),
                    SignalBuilder(builder: (context) {
                      final ready = coord.selfMember.value?.ready ?? false;
                      final pos = playback.position.value, dur = playback.duration.value;
                      return Row(
                        children: [
                          IconButton(
                            focusNode: _noFocus,
                            tooltip: ready ? 'Ready (click: not ready)' : 'Not ready (click: ready)',
                            onPressed: coord.toggleReady,
                            icon: Icon(
                              ready ? Icons.check_circle : Icons.radio_button_unchecked,
                              color: ready ? Colors.greenAccent : Colors.white,
                            ),
                          ),
                          Text('${formatClock(pos)} / ${formatClock(dur)}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          const Spacer(),
                          Flexible(
                            child: Text(playerStatusNow()?.short ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.amber, fontSize: 12)),
                          ),
                          const SizedBox(width: 10),
                        ],
                      );
                    }),
                    _MiniSeekBar(onSeek: (d) => playback.player.seek(d)),
                  ],
                ),
              ),
            ),
          ),
          if (!_miniHover)
            const Positioned(left: 0, right: 0, bottom: 0, child: _MiniSeekBar(thin: true)),
        ],
      ),
    );
  }
}

/// A floating pill's visibility: only while the controls are up (the
/// mouse moved) or the mouse is on it. With [announce] it is also up for
/// [firstShown] whenever [kind] changes (a new offer: Skip OP, Skip 1:30).
/// Gone with the offer (the parent drops it). The mouse on it holds
/// [hold]: it counts as the mouse on the controls.
class PillGate extends StatefulWidget {
  static const firstShown = Duration(seconds: 5);
  final Object kind;
  final bool announce;
  final ValueListenable<bool> controlsShown;
  final ControlsHold? hold;
  final Widget child;
  const PillGate({
    super.key,
    required this.kind,
    this.announce = false,
    required this.controlsShown,
    this.hold,
    required this.child,
  });

  @override
  State<PillGate> createState() => _PillGateState();
}

class _PillGateState extends State<PillGate> {
  Object? _kind;
  bool _fresh = false;
  bool _hover = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(PillGate old) {
    super.didUpdateWidget(old);
    if (widget.kind != _kind) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _kind = widget.kind;
    _timer?.cancel();
    _fresh = widget.announce;
    if (!_fresh) return;
    _timer = Timer(PillGate.firstShown, () {
      if (mounted) setState(() => _fresh = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The pill covers the controls' hover area: on it, [hold] keeps them
    // up (and it stays while the mouse is on it).
    return ValueListenableBuilder<bool>(
      valueListenable: widget.controlsShown,
      builder: (context, shown, child) {
        final on = _fresh || shown || _hover;
        return IgnorePointer(
          ignoring: !on,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AnimatedOpacity(duration: easeTime, curve: ease, opacity: on ? 1 : 0, child: child),
          ),
        );
      },
      child: ControlsHoldRegion(hold: widget.hold, child: widget.child),
    );
  }
}

enum _ActionSlot { status, side }

/// The action area's two slots, at its bottom: [_ActionSlot.side] at the
/// right end, [_ActionSlot.status] centred, moved left only as far as it
/// must to keep [gap] from the side (and never wider than what is left).
class _ActionAreaLayout extends MultiChildLayoutDelegate {
  final double gap;
  _ActionAreaLayout({required this.gap});

  @override
  void performLayout(Size size) {
    final side = layoutChild(_ActionSlot.side, BoxConstraints.loose(size));
    positionChild(_ActionSlot.side, Offset(size.width - side.width, size.height - side.height));
    final room = side.width > 0 ? size.width - side.width - gap : size.width;
    final status = layoutChild(_ActionSlot.status, BoxConstraints.loose(Size(math.max(0, room), size.height)));
    final x = math.min((size.width - status.width) / 2, room - status.width);
    positionChild(_ActionSlot.status, Offset(math.max(0, x), size.height - status.height));
  }

  @override
  bool shouldRelayout(_ActionAreaLayout old) => old.gap != gap;
}

const _shaderKeys = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

/// Mini player progress: a 2 px line, or (hovered) a 4 px bar that seeks.
class _MiniSeekBar extends StatelessWidget {
  final bool thin;
  final ValueChanged<Duration>? onSeek;
  const _MiniSeekBar({this.thin = false, this.onSeek});

  @override
  Widget build(BuildContext context) {
    final playback = SessionState.instance.coordinator.playback;
    return SignalBuilder(builder: (context) {
      final d = playback.duration.value;
      final p = playback.position.value;
      final v = d.inMilliseconds == 0 ? 0.0 : (p.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
      final bar = LinearProgressIndicator(
        value: v,
        minHeight: thin ? 2 : 4,
        backgroundColor: thin ? Colors.transparent : Colors.white24,
      );
      if (thin || onSeek == null || d == Duration.zero) return bar;
      void seekAt(double x, double width) => onSeek!(d * (x / width).clamp(0.0, 1.0));
      return LayoutBuilder(
        builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (e) => seekAt(e.localPosition.dx, box.maxWidth),
          onHorizontalDragEnd: null,
          onHorizontalDragUpdate: (e) => seekAt(e.localPosition.dx, box.maxWidth),
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: bar),
        ),
      );
    });
  }
}
