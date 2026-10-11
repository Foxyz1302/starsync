import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../controls/controls_probe.dart';
import '../controls/player_settings.dart';
import '../controls/uosc/buttons.dart';
import '../controls/uosc/controls.dart';
import '../controls/uosc/timeline.dart';
import '../controls/volume.dart';
import '../playback/media_marks.dart' show SkipKind, SkipOffer, formatClock;
import '../screens/session/jellyfin_widgets.dart';
import '../screens/session/player_controls.dart';
import '../session/session_coordinator.dart';
import '../shaders/shader_menu.dart';
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
/// everything over it. Full: our bars on media_kit's controls or the uosc
/// set (Settings), the start card, the status pill, Jellyfin overlays and
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
  bool _shaderMenuOpen = false;
  // Own toast ids, negative: the coordinator counts up from 1.
  int _toastSeq = 0;
  int _shaderNoticeSeen = 0;
  bool _miniHover = false;
  // Whether the controls are up: the standard ones tracked like media_kit
  // does (shown on mount and on mouse movement, hidden 3 s later or on
  // exit), the uosc ones reporting it.
  final _controlsShown = ValueNotifier(true);

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
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKey);
    AppKeys.removeChatToggle(_toggleChat);
    _stopShaderWatch();
    _noFocus.dispose();
    _controlsShown.dispose();
    super.dispose();
  }

  void _reloadVideo() {
    _coord.markInput();
    _coord.reloadVideo();
  }

  void _toast(String text) {
    _coord.toasts.value = [
      ..._coord.toasts.peek(),
      ToastItem(id: --_toastSeq, text: text, at: DateTime.now().toUtc()),
    ];
  }

  /// Menu, Ctrl+0..6: saved as the choice (also used on the next join)
  /// and applied live. A null quality keeps the saved one.
  void _pickShader(ShaderPreset preset, ShaderQuality? quality) => applyShaderChoice(preset, quality);

  void _toggleChat() {
    _coord.markInput();
    widget.onToggleChat();
  }

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
      if (_shaderMenuOpen && event.logicalKey == LogicalKeyboardKey.escape) {
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
    final coord = _coord;
    final key = event.logicalKey;
    // Ctrl+0..6: Anime4K's own mpv keys (off, modes A..C+A).
    final digit = _shaderKeys.indexOf(key);
    if (digit >= 0 && HardwareKeyboard.instance.isControlPressed) {
      _lastKeyAt = now;
      _pickShader(digit == 0 ? ShaderPreset.off : ShaderPreset.modes[digit - 1], null);
      return true;
    }
    if (key == LogicalKeyboardKey.keyR && HardwareKeyboard.instance.isControlPressed) {
      _lastKeyAt = now;
      _reloadVideo();
      return true;
    }
    // mpv's playlist keys (< >) and Shift+P / Shift+N: Jellyfin episodes.
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.character == '>' || (shift && key == LogicalKeyboardKey.keyN)) {
      if (coord.nextEpisode.peek() == null) return false;
      _lastKeyAt = now;
      coord.playNextEpisode();
      return true;
    }
    if (event.character == '<' || (shift && key == LogicalKeyboardKey.keyP)) {
      if (coord.previousEpisode.peek() == null) return false;
      _lastKeyAt = now;
      coord.playPreviousEpisode();
      return true;
    }
    // mpv's chapter keys.
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.pageUp) {
      _lastKeyAt = now;
      return coord.stepChapter(key == LogicalKeyboardKey.pageDown ? 1 : -1);
    }
    if (shift && key == LogicalKeyboardKey.arrowRight) {
      _lastKeyAt = now;
      coord.skipForward();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      final player = coord.playback.player;
      player.setVolume(stepVolume(player.state.volume, key == LogicalKeyboardKey.arrowUp ? 5 : -5));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _lastKeyAt = now;
      coord.nudge(10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _lastKeyAt = now;
      coord.nudge(-10);
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
          return Stack(
            fit: StackFit.expand,
            children: [
              video,
              if (_full) ...[
                _status(),
                _progressLine(),
                _jellyfinOverlay(),
                if (widget.fullscreen) ...[if (!SessionState.instance.solo.value) _pausedParty(), _unreadChip()],
              ] else
                _miniOverlay(),
              // Sitting out: nothing is loaded; the card covers the
              // empty player (which stays mounted for joining back).
              if (_coord.selfOut.value) _sitOut(),
            ],
          );
        }),
      ),
    );
  }

  Widget _video(VideoControlsBuilder? controls) {
    final theme = _controlsTheme();
    return MaterialDesktopVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: Video(
        key: _videoKey,
        controller: _coord.playback.video,
        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
        controls: controls,
      ),
    );
  }

  static const _barHeight = 56.0;
  /// The standard top bar: room for the cover (2:3, 60 px tall).
  static const _topBarHeight = 72.0;
  static const _controlsHide = Duration(seconds: 3);

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

  /// The standard design's progress line while its controls are hidden
  /// (the uosc timeline collapses into its own).
  Widget _progressLine() => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
          child: SignalBuilder(builder: (context) {
            final s = AppSettings.instance;
            if (s.mpvControls.value || !s.progressLine.value) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: _controlsShown,
              builder: (context, shown, _) => shown
                  ? const SizedBox.shrink()
                  : const _MiniSeekBar(key: ValueKey('progress-line-standard'), thin: true),
            );
          }),
        ),
      );

  MaterialDesktopVideoControlsThemeData _controlsTheme() {
    final coord = _coord;
    return MaterialDesktopVideoControlsThemeData(
      playAndPauseOnTap: false,
      modifyVolumeOnScroll: false,
      // media_kit's double-click pushes its own fullscreen route (a second
      // `Video`); ours toggles the window instead (see [DoubleClickListener]).
      toggleFullscreenOnDoublePress: false,
      keyboardShortcuts: {},
      visibleOnMount: true,
      hideMouseOnControlsRemoval: true,
      controlsHoverDuration: _controlsHide,
      // Our seek bar (chapter marks, hover title) sits in the bottom bar,
      // which grows by its height; the top bar keeps its row at the top.
      displaySeekBar: false,
      buttonBarHeight: _barHeight + ChapterSeekBar.height,
      topButtonBar: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: _topBarHeight,
              child: Row(
                children: [
                  const Expanded(child: NowPlayingTitle()),
                  MaterialDesktopCustomButton(
                    icon: const Icon(Icons.video_library_outlined),
                    onPressed: widget.onChangeVideo,
                  ),
                  MaterialDesktopCustomButton(
                    icon: Badge(
                      isLabelVisible: widget.unread > 0,
                      label: Text('${widget.unread}'),
                      child: Icon(widget.chatOpen ? Icons.chat_bubble : Icons.chat_bubble_outline),
                    ),
                    onPressed: _toggleChat,
                  ),
                  MaterialDesktopCustomButton(
                    icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.close_fullscreen),
                    onPressed: widget.fullscreen ? widget.onToggleFullscreen : widget.onCollapse,
                  ),
                  ?_fullscreenWindowButtons(),
                ],
              ),
            ),
          ),
        ),
      ],
      bottomButtonBar: [
        Expanded(
          child: Column(
            children: [
              SignalBuilder(
                builder: (context) => PlayerSeekBar(
                  player: coord.playback.player,
                  chapters: coord.playback.chapters.value,
                ),
              ),
              Expanded(child: Row(children: _bottomButtons())),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _bottomButtons() {
    final coord = _coord;
    final playback = coord.playback;
    void menuOpen(bool open) => _shaderMenuOpen = open;
    void pickTrack(TrackPick p) => coord.selectTrack(aid: p.aid, sid: p.sid, subtitlesOff: p.subtitlesOff);
    return [
      SignalBuilder(
        builder: (context) => EpisodeSkipButton(
          focusNode: _noFocus,
          episode: coord.previousEpisode.value,
          next: false,
          onPressed: coord.playPreviousEpisode,
        ),
      ),
      SignalBuilder(
        builder: (context) => EpisodeSkipButton(
          focusNode: _noFocus,
          episode: coord.nextEpisode.value,
          next: true,
          onPressed: coord.playNextEpisode,
        ),
      ),
      VolumeButton(player: playback.player, focusNode: _noFocus),
      _ReadyControlButton(focusNode: _noFocus),
      _BarTextButton(
        focusNode: _noFocus,
        label: 'Mark everyone ready',
        onPressed: coord.forcePlayAll,
      ),
      _BarTextButton(
        focusNode: _noFocus,
        icon: Icons.refresh,
        label: 'Reload video',
        tooltip: 'Reload video (Ctrl+R) — fixes a frozen picture',
        onPressed: _reloadVideo,
      ),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      SkipForwardButton(focusNode: _noFocus, onPressed: coord.skipForward),
      SignalBuilder(
        builder: (context) => ChaptersControlButton(
          focusNode: _noFocus,
          chapters: playback.chapters.value,
          current: playback.currentChapter.value,
          onPick: (c) => coord.seekTo(c.start.inMicroseconds / 1e6),
          onMenuOpen: menuOpen,
        ),
      ),
      SignalBuilder(
        builder: (context) => TrackMenuButton(
          focusNode: _noFocus,
          type: JellyfinStreamType.audio,
          tracks: playback.tracks.value,
          onPick: pickTrack,
          onMenuOpen: menuOpen,
        ),
      ),
      SignalBuilder(
        builder: (context) => TrackMenuButton(
          focusNode: _noFocus,
          type: JellyfinStreamType.subtitle,
          tracks: playback.tracks.value,
          onPick: pickTrack,
          onMenuOpen: menuOpen,
        ),
      ),
      ShaderControlButton(
        focusNode: _noFocus,
        renderMode: playback.renderMode,
        onPick: _pickShader,
        onMenuOpen: menuOpen,
      ),
      PlayerSettingsButton(focusNode: _noFocus, renderMode: playback.renderMode),
      MaterialDesktopCustomButton(
        icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        onPressed: widget.onToggleFullscreen,
      ),
    ];
  }

  Widget _sessionControls(VideoState state) {
    // The start card sits under the controls (they stay usable on it).
    // The "Player design" setting swaps them live.
    return Stack(fit: StackFit.expand, children: [const StartBanner(), _controlsSwitch(state)]);
  }

  Widget _controlsSwitch(VideoState state) {
    return SessionControlsSwitch(
      material: (_) => ControlsHoverProbe(
        shown: _controlsShown,
        hideAfter: _controlsHide,
        child: DoubleClickListener(
          onDoubleClick: widget.onToggleFullscreen,
          // Clicks on the bars are button clicks, not the video.
          skipTop: _topBarHeight,
          skipBottom: _barHeight + ChapterSeekBar.height,
          child: MaterialDesktopVideoControls(state),
        ),
      ),
      mpv: (_) => _mpvControls(),
    );
  }

  /// The uosc controls: same actions as the bars above,
  /// all through the coordinator (seeks via `player.seek`, the user path).
  Widget _mpvControls() {
    final coord = _coord;
    final playback = coord.playback;
    void menuOpen(bool open) => _shaderMenuOpen = open;
    void pickTrack(TrackPick p) => coord.selectTrack(aid: p.aid, sid: p.sid, subtitlesOff: p.subtitlesOff);
    Widget episode(bool next) => SignalBuilder(builder: (context) {
          final e = next ? coord.nextEpisode.value : coord.previousEpisode.value;
          if (e == null) return const SizedBox.shrink();
          return UoscButton(
            key: ValueKey(next ? 'episode-next' : 'episode-previous'),
            icon: next ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
            tooltip: '${next ? 'Next' : 'Previous'}: ${e.label}  (${next ? '> or Shift+N' : '< or Shift+P'})',
            onPressed: next ? coord.playNextEpisode : coord.playPreviousEpisode,
          );
        });
    return UoscControls(
      shown: _controlsShown,
      onDoubleTap: widget.onToggleFullscreen,
      topLeft: const NowPlayingTitle(),
      top: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UoscButton(
            key: const ValueKey('uosc-chat'),
            icon: widget.chatOpen ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
            tooltip: 'Chat & activity (Tab)',
            badge: widget.unread,
            onPressed: _toggleChat,
          ),
          UoscButton(
            icon: widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.close_fullscreen_rounded,
            tooltip: widget.fullscreen ? 'Exit fullscreen (Esc)' : 'Back to the library (keeps playing)',
            onPressed: widget.fullscreen ? widget.onToggleFullscreen : widget.onCollapse,
          ),
          ?_fullscreenWindowButtons(),
        ],
      ),
      timeline: (context, expanded) => SignalBuilder(
        builder: (context) => UoscTimeline(
          position: playback.position.value,
          duration: playback.duration.value,
          buffered: playback.buffered.value,
          chapters: playback.chapters.value,
          expanded: expanded,
          onSeek: (d) => playback.player.seek(d),
        ),
      ),
      left: [
        UoscMainMenuButton(
          onMenuOpen: menuOpen,
          actions: [
            (title: 'Change video', hint: null, run: widget.onChangeVideo),
            (title: 'Chat & activity', hint: 'Tab', run: _toggleChat),
            (title: 'Reload video', hint: 'Ctrl+R', run: _reloadVideo),
            (title: 'Mark everyone ready', hint: null, run: coord.forcePlayAll),
            (title: 'Fullscreen', hint: 'F', run: widget.onToggleFullscreen),
            (title: 'Leave server', hint: 'Esc', run: widget.onLeave),
          ],
        ),
        SignalBuilder(
          builder: (context) => UoscTracksButton(
            type: JellyfinStreamType.subtitle,
            tracks: playback.tracks.value,
            onPick: pickTrack,
            onMenuOpen: menuOpen,
          ),
        ),
        SignalBuilder(
          builder: (context) => UoscTracksButton(
            type: JellyfinStreamType.audio,
            tracks: playback.tracks.value,
            onPick: pickTrack,
            onMenuOpen: menuOpen,
          ),
        ),
        UoscShaderButton(renderMode: playback.renderMode, onPick: _pickShader, onMenuOpen: menuOpen),
        const SizedBox(width: 12),
        SignalBuilder(builder: (context) {
          final ready = coord.selfMember.value?.ready ?? false;
          return UoscButton(
            key: const ValueKey('uosc-ready'),
            icon: ready ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            label: ready ? 'Ready' : 'Not ready',
            color: ready ? Colors.greenAccent : null,
            tooltip: 'Ready / not ready (Space)',
            onPressed: coord.toggleReady,
          );
        }),
        UoscButton(icon: Icons.done_all_rounded, tooltip: 'Mark everyone ready', onPressed: coord.forcePlayAll),
        UoscButton(
          icon: Icons.refresh_rounded,
          tooltip: 'Reload video (Ctrl+R) — fixes a frozen picture',
          onPressed: _reloadVideo,
        ),
      ],
      right: [
        UoscButton(
          key: const ValueKey('uosc-skip-forward'),
          icon: Icons.fast_forward_rounded,
          label: '1:30',
          tooltip: 'Skip 1:30 for everyone (Shift+Right)',
          onPressed: coord.skipForward,
        ),
        SignalBuilder(
          builder: (context) => UoscChaptersButton(
            chapters: playback.chapters.value,
            current: playback.currentChapter.value,
            duration: playback.duration.value,
            onPick: (c) => coord.seekTo(c.start.inMicroseconds / 1e6),
            onMenuOpen: menuOpen,
          ),
        ),
        episode(false),
        episode(true),
        const SizedBox(width: 12),
        UoscButton(icon: Icons.video_library_outlined, tooltip: 'Change video', onPressed: widget.onChangeVideo),
        StreamBuilder<double>(
          stream: playback.player.stream.volume,
          initialData: playback.player.state.volume,
          builder: (context, v) => UoscVolumeButton(
            volume: v.data ?? 100,
            onChanged: (x) => playback.player.setVolume(x),
          ),
        ),
        UoscPlayerSettingsButton(renderMode: playback.renderMode),
        UoscButton(
          icon: widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          tooltip: 'Fullscreen (F)',
          onPressed: widget.onToggleFullscreen,
        ),
      ],
    );
  }

  /// The one status pill, bottom centre above the controls.
  Widget _status() =>
      const Positioned(left: 16, right: 16, bottom: 124, child: Center(child: PlayerStatus()));

  /// Jellyfin: the blocked card, the end-of-episode card (countdown) and
  /// the "Next episode" pill; for any media the skip pill (Skip OP / ED /
  /// 1:30) above it ([SkipPillGate]). Outside the auto-hiding controls, so
  /// they stay up.
  Widget _jellyfinOverlay() {
    final coord = _coord;
    return Positioned.fill(
      child: SignalBuilder(
        builder: (context) {
          final blocked = coord.jellyfinBlocked.value;
          final next = coord.nextEpisode.value;
          final countdown = coord.autoAdvance.value;
          final finished = coord.serverState.value?.transport == 'finished';
          final pill = coord.nextPromptVisible.value;
          final SkipOffer? skip = coord.skipOffer.value;
          final showNext = next != null && pill;
          return Stack(
            children: [
              if (blocked != null)
                Center(
                  child: JellyfinBlockedCard(
                    blocked: blocked,
                    onLinkAccount: widget.onOpenIntegrations,
                    onRetry: coord.retryJellyfin,
                  ),
                ),
              if (next != null && (finished || countdown != null))
                Positioned(
                  right: 24,
                  bottom: 138,
                  child: EndOfEpisodeCard(
                    next: next,
                    countdown: countdown,
                    onPlayNow: coord.playNextEpisode,
                    onCancel: coord.cancelAutoAdvance,
                  ),
                )
              else if (showNext || skip != null)
                Positioned(
                  right: 24,
                  bottom: 124,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    spacing: 10,
                    children: [
                      if (skip != null)
                        SkipPillGate(
                          key: const ValueKey('skip-gate'),
                          offer: skip,
                          controlsShown: _controlsShown,
                          child: SkipPill(offer: skip, onPressed: () => coord.skip(skip)),
                        ),
                      if (showNext) NextEpisodePill(episode: next, onPressed: coord.playNextEpisode),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Fullscreen hides the strip: while paused the party stays in a corner.
  Widget _pausedParty() => Positioned(
        right: 16,
        top: _barHeight + 8,
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
        right: 16,
        top: 16,
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

/// The skip pill's visibility: up for [firstShown] after an offer
/// appears (a new kind: OP, ED, 1:30), then only while the controls are
/// up or the mouse is on it; gone with the offer (the parent drops it).
class SkipPillGate extends StatefulWidget {
  static const firstShown = Duration(seconds: 5);
  final SkipOffer offer;
  final ValueListenable<bool> controlsShown;
  final Widget child;
  const SkipPillGate({super.key, required this.offer, required this.controlsShown, required this.child});

  @override
  State<SkipPillGate> createState() => _SkipPillGateState();
}

class _SkipPillGateState extends State<SkipPillGate> {
  SkipKind? _kind;
  bool _fresh = false;
  bool _hover = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(SkipPillGate old) {
    super.didUpdateWidget(old);
    if (widget.offer.kind != _kind) _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _kind = widget.offer.kind;
    _fresh = true;
    _timer?.cancel();
    _timer = Timer(SkipPillGate.firstShown, () {
      if (mounted) setState(() => _fresh = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The pill covers the controls' hover area: on it, they may hide while
    // it stays.
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
      child: widget.child,
    );
  }
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
  const _MiniSeekBar({super.key, this.thin = false, this.onSeek});

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

/// Double-click on the picture (not on the bars) without joining the
/// gesture arena, so single clicks on buttons stay instant.
class DoubleClickListener extends StatefulWidget {
  final VoidCallback onDoubleClick;
  final double skipTop, skipBottom;
  final Widget child;
  const DoubleClickListener(
      {super.key, required this.onDoubleClick, this.skipTop = 0, this.skipBottom = 0, required this.child});

  @override
  State<DoubleClickListener> createState() => _DoubleClickListenerState();
}

class _DoubleClickListenerState extends State<DoubleClickListener> {
  DateTime? _last;
  Offset? _lastAt;

  void _down(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton) return;
    final h = context.size?.height ?? 0;
    final y = e.localPosition.dy;
    if (y < widget.skipTop || y > h - widget.skipBottom) {
      _last = null;
      return;
    }
    final now = DateTime.now();
    final last = _last, at = _lastAt;
    if (last != null &&
        at != null &&
        now.difference(last) < const Duration(milliseconds: 400) &&
        (e.localPosition - at).distance < 24) {
      _last = null;
      widget.onDoubleClick();
      return;
    }
    _last = now;
    _lastAt = e.localPosition;
  }

  @override
  Widget build(BuildContext context) =>
      Listener(behavior: HitTestBehavior.translucent, onPointerDown: _down, child: widget.child);
}

class _ReadyControlButton extends StatelessWidget {
  final FocusNode focusNode;
  const _ReadyControlButton({required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final ready = SessionState.instance.coordinator.selfMember.value?.ready ?? false;
        return _BarTextButton(
          focusNode: focusNode,
          label: ready ? 'Ready ✓' : 'Not ready',
          onPressed: SessionState.instance.coordinator.toggleReady,
        );
      },
    );
  }
}

class _BarTextButton extends StatelessWidget {
  final FocusNode focusNode;
  final String label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onPressed;
  const _BarTextButton(
      {required this.focusNode, required this.label, required this.onPressed, this.icon, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final text = Text(label, style: const TextStyle(fontSize: 12));
    final button = icon == null
        ? TextButton(focusNode: focusNode, style: style, onPressed: onPressed, child: text)
        : TextButton.icon(
            focusNode: focusNode, style: style, onPressed: onPressed, icon: Icon(icon, size: 16), label: text);
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
