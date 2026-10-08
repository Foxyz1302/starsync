import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../controls/uosc/buttons.dart';
import '../controls/uosc/controls.dart';
import '../controls/uosc/timeline.dart';
import '../playback/media_marks.dart' show SkipOffer, formatClock;
import '../screens/session/jellyfin_widgets.dart';
import '../screens/session/player_controls.dart';
import '../session/health.dart';
import '../session/session_coordinator.dart';
import '../shaders/shader_menu.dart';
import '../shaders/shader_presets.dart';
import '../state/session_state.dart';
import '../state/settings.dart';
import '../widgets/shown_frame_probe.dart';
import '../widgets/text_focus.dart';
import 'avatar.dart';
import 'motion.dart';

/// Where the session's video is shown: nowhere, the floating mini player,
/// or filling the body (and, with fullscreen, the window).
enum PlayerMode { none, mini, full }

/// Builds the one video view of the current player around [controls]
/// (null: none, the mini player). Tests pass a stand-in: media_kit's
/// `Video` hangs flutter_test.
typedef VideoViewBuilder = Widget Function(BuildContext context, VideoControlsBuilder? controls);

/// The session's player: the one `Video` of the current player and
/// everything over it. Full: our bars on media_kit's controls or the uosc
/// set (Settings), health / waiting / Jellyfin overlays and the player
/// keys. Mini: hover controls and a progress line. The shell keeps this
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
  });

  @override
  State<SessionPlayer> createState() => _SessionPlayerState();
}

class _SessionPlayerState extends State<SessionPlayer> {
  // One key per player generation: a reloaded player needs a fresh
  // `Video` (it never swaps controllers in place).
  var _videoGen = -1;
  var _videoKey = GlobalKey<VideoState>();
  final _frameProbe = ShownFrameProbe();
  final _noFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  DateTime? _lastKeyAt;
  late final void Function() _stopShaderWatch;
  bool _shaderMenuOpen = false;
  // Own toast ids, negative: the coordinator counts up from 1.
  int _toastSeq = 0;
  int _shaderNoticeSeen = 0;
  bool _miniHover = false;

  SessionCoordinator get _coord => SessionState.instance.coordinator;
  bool get _full => widget.mode == PlayerMode.full;

  @override
  void initState() {
    super.initState();
    _coord.jellyfin.ensureLoaded();
    _coord.playback.shownFrame = _frameProbe.sample;
    HardwareKeyboard.instance.addHandler(_globalKey);
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
    final playback = _coord.playback;
    if (playback.shownFrame == _frameProbe.sample) playback.shownFrame = null;
    _stopShaderWatch();
    _noFocus.dispose();
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
  void _pickShader(ShaderPreset preset, ShaderQuality? quality) {
    final s = AppSettings.instance;
    if (quality != null) s.setShaderQuality(quality);
    s.setShaderPreset(preset);
    _coord.markInput();
    _coord.playback.applyShaders(announce: true);
  }

  void _toggleChat() {
    _coord.markInput();
    widget.onToggleChat();
  }

  /// The player keys, while the player fills the body and nothing (a
  /// dialog, a card, a text field) is in front of it.
  bool _globalKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted || !_full) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) return false;
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
    if (key == LogicalKeyboardKey.space) {
      _lastKeyAt = now;
      coord.toggleReady();
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
    if (key == LogicalKeyboardKey.tab) {
      _lastKeyAt = now;
      _toggleChat();
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
        widget.onLeave();
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
              // The frozen-picture watchdog captures this boundary: the
              // video (and its controls), not the window around it.
              RepaintBoundary(
                child: Stack(fit: StackFit.expand, children: [video, _frameProbe.anchor()]),
              ),
              if (_full) ...[
                _healthOverlay(),
                _waitingPill(bottom: 124),
                _jellyfinOverlay(),
                if (widget.fullscreen) _pausedParty(),
              ] else
                _miniOverlay(),
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

  String get _title {
    final ref = _coord.currentRef.value;
    if (ref != null && ref.title.isNotEmpty) {
      return [ref.title, ?ref.subtitle].join(' · ');
    }
    return (_coord.serverState.value?.media?['name'] as String?) ?? '';
  }

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
      controlsHoverDuration: const Duration(seconds: 3),
      // Our seek bar (chapter marks, hover title) sits in the bottom bar,
      // which grows by its height; the top bar keeps its row at the top.
      displaySeekBar: false,
      buttonBarHeight: _barHeight + ChapterSeekBar.height,
      topButtonBar: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: _barHeight,
              child: Row(
                children: [
                  Expanded(
                    child: SignalBuilder(
                      builder: (context) => Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                    ),
                  ),
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
      const MaterialDesktopVolumeButton(),
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
      MaterialDesktopCustomButton(
        icon: Icon(widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        onPressed: widget.onToggleFullscreen,
      ),
    ];
  }

  Widget _sessionControls(VideoState state) {
    // Settings → "Experimental: mpv-style controls" swaps them live.
    return SessionControlsSwitch(
      material: (_) => DoubleClickListener(
        onDoubleClick: widget.onToggleFullscreen,
        // Clicks on the bars are button clicks, not the video.
        skipTop: _barHeight,
        skipBottom: _barHeight + ChapterSeekBar.height,
        child: MaterialDesktopVideoControls(state),
      ),
      mpv: (_) => _mpvControls(),
    );
  }

  /// The experimental uosc-style controls: same actions as the bars above,
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
      onDoubleTap: widget.onToggleFullscreen,
      top: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UoscButton(icon: Icons.chat_bubble_outline_rounded, tooltip: 'Chat & activity (Tab)', onPressed: _toggleChat),
          UoscButton(
            icon: widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.close_fullscreen_rounded,
            tooltip: widget.fullscreen ? 'Exit fullscreen (Esc)' : 'Back to the library (keeps playing)',
            onPressed: widget.fullscreen ? widget.onToggleFullscreen : widget.onCollapse,
          ),
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
        UoscButton(
          icon: widget.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          tooltip: 'Fullscreen (F)',
          onPressed: widget.onToggleFullscreen,
        ),
      ],
    );
  }

  Widget _healthOverlay() {
    final coord = _coord;
    return Positioned(
      top: _barHeight + 8,
      left: 12,
      right: 12,
      child: Align(
        alignment: Alignment.topLeft,
        child: SignalBuilder(
          builder: (context) {
            final h = coord.health.value;
            final starve = coord.starving.value;
            final retrying = coord.reconnecting.value;
            final kicked = coord.kickReason.value;
            final unwell = h.severity == HealthSeverity.warn ||
                h.severity == HealthSeverity.error ||
                retrying ||
                starve != null;
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
            final text = [h.message, ?starve, if (retrying) 'reconnecting…'].join(' · ');
            final canRetry = !retrying &&
                kicked == null &&
                (h.severity == HealthSeverity.error || h.severity == HealthSeverity.warn);
            final button = TextButton.styleFrom(
                foregroundColor: Colors.white, tapTargetSize: MaterialTapTargetSize.shrinkWrap);
            return Container(
              decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(999)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 16),
                  const SizedBox(width: 8),
                  Flexible(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12))),
                  if (retrying)
                    TextButton(
                      style: button,
                      onPressed: coord.cancelReconnect,
                      child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                    ),
                  if (canRetry)
                    TextButton(
                      style: button,
                      onPressed: coord.retry,
                      child: const Text('Retry', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _waitingPill({required double bottom}) =>
      Positioned(left: 0, right: 0, bottom: bottom, child: const Center(child: WaitingPill()));

  /// Jellyfin: the blocked card, the end-of-episode card (countdown) and
  /// the "Next episode" pill; for any media the skip pill (Skip OP / ED /
  /// 1:30) above it. Outside the auto-hiding controls, so they stay up.
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
                      if (skip != null) SkipPill(offer: skip, onPressed: () => coord.skip(skip)),
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

  /// Mini: title, expand and close on hover; ready, time and a seekable
  /// bar at the bottom. A thin progress line stays while not hovered.
  Widget _miniOverlay() {
    final coord = _coord;
    final playback = coord.playback;
    const white = TextStyle(color: Colors.white, fontWeight: FontWeight.w600);
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
                        Expanded(
                          child: SignalBuilder(
                            builder: (context) =>
                                Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: white),
                          ),
                        ),
                        IconButton(
                          focusNode: _noFocus,
                          onPressed: widget.onExpand,
                          tooltip: 'Expand',
                          icon: const Icon(Icons.open_in_full, color: Colors.white, size: 18),
                        ),
                        IconButton(
                          focusNode: _noFocus,
                          onPressed: widget.onClose,
                          tooltip: 'Stop watching (stay in the server)',
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
                            child: Text(waitingText(compact: true),
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

const _shaderKeys = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
];

/// Who the server waits for: "Waiting for you · press Space when ready",
/// "Waiting for Alex, Mika", or '' while playing or with nothing up.
String waitingText({bool compact = false}) {
  final coord = SessionState.instance.coordinator;
  final r = coord.serverState.value;
  if (r == null || r.media == null || r.transport != 'held') return '';
  final self = coord.selfMember.value;
  if (self != null && !self.ready) {
    return compact ? 'waiting for you' : 'Waiting for you · press Space when ready';
  }
  final waiting = [for (final m in r.members) if (!m.ready && !m.stale) m.name];
  if (waiting.isEmpty) return compact ? '' : 'Paused';
  return '${compact ? 'waiting' : 'Waiting'} for ${waiting.join(', ')}';
}

/// While held: who everyone is waiting for, with their avatars. When it
/// is you, a click marks you ready.
class WaitingPill extends StatelessWidget {
  const WaitingPill({super.key});

  @override
  Widget build(BuildContext context) {
    return PartyWatch(builder: (context) {
      final coord = SessionState.instance.coordinator;
      final text = waitingText();
      final r = coord.serverState.value;
      final self = coord.selfMember.value;
      final meWaiting = self != null && !self.ready;
      final who = meWaiting
          ? [selfAvatarInfo()]
          : [
              for (final m in r?.members ?? const <MemberView>[])
                if (!m.ready && !m.stale) memberAvatarInfo(m, r, coord),
            ];
      return AnimatedOpacity(
        duration: easeTime,
        curve: ease,
        opacity: text.isEmpty ? 0 : 1,
        child: IgnorePointer(
          ignoring: text.isEmpty || !meWaiting,
          child: GestureDetector(
            key: const ValueKey('waiting-pill'),
            onTap: coord.toggleReady,
            child: MouseRegion(
              cursor: meWaiting ? SystemMouseCursors.click : MouseCursor.defer,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in who.take(4))
                      Padding(padding: const EdgeInsets.only(right: 4), child: StatusAvatar(info: m, size: 28)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

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
