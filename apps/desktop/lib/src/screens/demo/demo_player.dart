part of 'shell_demo.dart';

// DEBUG ONLY: a real media_kit player for the layout demo. One Player and
// VideoController, shown by whichever view is active (mini, full or
// fullscreen); only one Video widget is mounted at a time.

class _DemoMedia {
  final String title;
  final String subtitle;
  final String? path;
  const _DemoMedia(this.title, this.subtitle, [this.path]);
}

/// What is playing; null = nothing.
final _nowPlaying = ValueNotifier<_DemoMedia?>(null);
Player? _demoPlayer;
VideoController? _demoVideo;

Future<void> _playMedia(_DemoMedia m) async {
  _nowPlaying.value = m;
  if (m.path == null) return;
  final p = _demoPlayer ??= Player();
  _demoVideo ??= VideoController(p);
  await p.open(Media(m.path!));
}

Future<void> _disposeDemoPlayer() async {
  final p = _demoPlayer;
  _demoPlayer = null;
  _demoVideo = null;
  _nowPlaying.value = null;
  await p?.dispose();
}

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// The video itself, or a placeholder when nothing real is open.
class _VideoSurface extends StatelessWidget {
  final double placeholderSize;
  const _VideoSurface({this.placeholderSize = 32});

  @override
  Widget build(BuildContext context) {
    final v = _demoVideo;
    if (v == null || _nowPlaying.value?.path == null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Text(
          'video · play something from Files',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white24,
            fontSize: placeholderSize * 0.6,
          ),
        ),
      );
    }
    return Video(controller: v, controls: NoVideoControls, fill: Colors.black);
  }
}

/// Position bar + play/pause + time, bound to the real player (inert
/// when nothing is open).
class _Transport extends StatelessWidget {
  final bool compact;
  final List<Widget> trailing;
  const _Transport({this.compact = false, this.trailing = const []});

  @override
  Widget build(BuildContext context) {
    final p = _demoPlayer;
    if (p == null) {
      return Row(
        children: [
          const IconButton(
            onPressed: null,
            icon: Icon(Icons.play_arrow, color: Colors.white38),
          ),
          const Text('--:-- / --:--', style: TextStyle(color: Colors.white38)),
          const Spacer(),
          ...trailing,
        ],
      );
    }
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      builder: (context, _) {
        final pos = p.state.position, dur = p.state.duration;
        final frac = dur.inMilliseconds == 0
            ? 0.0
            : pos.inMilliseconds / dur.inMilliseconds;
        final bar = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: compact ? 3 : 4,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: compact ? 0 : 7,
            ),
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: frac.clamp(0.0, 1.0),
            onChanged: dur == Duration.zero ? null : (v) => p.seek(dur * v),
          ),
        );
        final row = Row(
          children: [
            StreamBuilder<bool>(
              stream: p.stream.playing,
              builder: (context, _) => IconButton(
                onPressed: p.playOrPause,
                icon: Icon(
                  p.state.playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
              ),
            ),
            Text(
              '${_fmt(pos)} / ${_fmt(dur)}',
              style: TextStyle(
                color: Colors.white70,
                fontSize: compact ? 12 : 14,
              ),
            ),
            const Spacer(),
            ...trailing,
          ],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [if (!compact) bar, row, if (compact) bar],
        );
      },
    );
  }
}

/// Full and fullscreen player. Controls fade out after 2.5 s without the
/// mouse moving; in fullscreen the party sits top-right and toasts stay.
class _RealFullPlayer extends StatefulWidget {
  final bool fullscreen;
  final VoidCallback onCollapse, onToggleFullscreen;
  final Widget? partyOverlay;
  const _RealFullPlayer({
    required this.fullscreen,
    required this.onCollapse,
    required this.onToggleFullscreen,
    this.partyOverlay,
  });

  @override
  State<_RealFullPlayer> createState() => _RealFullPlayerState();
}

class _RealFullPlayerState extends State<_RealFullPlayer> {
  bool _shown = true;
  Timer? _hide;

  void _poke() {
    if (!_shown) setState(() => _shown = true);
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _shown = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _poke();
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = _nowPlaying.value;
    final controls = AnimatedOpacity(
      duration: _easeTime,
      curve: _ease,
      opacity: _shown ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_shown,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 28),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m?.title ?? 'Nothing playing',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            m?.subtitle ?? '',
                            style: const TextStyle(color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                    if (widget.partyOverlay != null) ...[
                      widget.partyOverlay!,
                      const SizedBox(width: 8),
                    ],
                    if (!widget.fullscreen)
                      IconButton(
                        onPressed: widget.onCollapse,
                        tooltip: 'Back to the library (keeps playing)',
                        icon: const Icon(
                          Icons.close_fullscreen,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: _Transport(
                  trailing: [
                    Builder(
                      builder: (context) => IconButton(
                        tooltip: 'Player settings',
                        onPressed: () => _popover(
                          context,
                          at: const Alignment(0.97, 0.78),
                          child: const _PlayerSettingsCard(),
                        ),
                        icon: const Icon(Icons.tune, color: Colors.white),
                      ),
                    ),
                    IconButton(
                      tooltip: widget.fullscreen
                          ? 'Exit fullscreen (Esc)'
                          : 'Fullscreen (F)',
                      onPressed: widget.onToggleFullscreen,
                      icon: Icon(
                        widget.fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF):
            widget.onToggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (widget.fullscreen) widget.onToggleFullscreen();
        },
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _demoPlayer?.playOrPause(),
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          onHover: (_) => _poke(),
          cursor: _shown ? MouseCursor.defer : SystemMouseCursors.none,
          child: GestureDetector(
            onDoubleTap: widget.onToggleFullscreen,
            onTap: () => _demoPlayer?.playOrPause(),
            child: Container(
              color: Colors.black,
              child: Stack(
                children: [
                  const Positioned.fill(child: _VideoSurface()),
                  Positioned.fill(child: controls),
                  // A thin progress line stays when the controls hide.
                  if (!_shown && _demoPlayer != null)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _ThinProgress(),
                    ),
                  // Paused: who everyone is waiting for, always visible.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _shown ? 96 : 28,
                    child: const Center(child: _WaitingPill()),
                  ),
                  // Fullscreen with the controls hidden: the party stays
                  // in the corner while paused.
                  if (widget.fullscreen &&
                      !_shown &&
                      widget.partyOverlay != null)
                    Positioned(
                      right: 16,
                      top: 14,
                      child: _PausedOnly(child: widget.partyOverlay!),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinProgress extends StatelessWidget {
  const _ThinProgress();

  @override
  Widget build(BuildContext context) {
    final p = _demoPlayer!;
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      builder: (context, _) {
        final d = p.state.duration.inMilliseconds;
        return LinearProgressIndicator(
          value: d == 0 ? 0 : p.state.position.inMilliseconds / d,
          minHeight: 2,
          backgroundColor: Colors.transparent,
        );
      },
    );
  }
}

/// The gear in the player: everything about the player lives here.
class _PlayerSettingsCard extends StatefulWidget {
  const _PlayerSettingsCard();

  @override
  State<_PlayerSettingsCard> createState() => _PlayerSettingsCardState();
}

class _PlayerSettingsCardState extends State<_PlayerSettingsCard> {
  String _design = 'Standard';
  bool _line = true;
  String _shader = 'Off';
  String _hwdec = 'Auto';
  double _subSize = 1;

  Widget _row(String label, Widget control, {String? help}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              if (help != null)
                Text(
                  help,
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
            ],
          ),
        ),
        control,
      ],
    ),
  );

  Widget _drop(String value, List<String> items, ValueChanged<String> on) =>
      DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        items: [
          for (final i in items) DropdownMenuItem(value: i, child: Text(i)),
        ],
        onChanged: (v) => setState(() => on(v!)),
      );

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Player',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 6),
              _row(
                'Player design',
                _drop(_design, const ['Standard', 'uosc'], (v) => _design = v),
              ),
              _row(
                'Progress line when hidden',
                Switch(
                  value: _line,
                  onChanged: (v) => setState(() => _line = v),
                ),
                help: 'A thin bar at the bottom while the controls are hidden',
              ),
              _row(
                'Upscaling shader',
                _drop(_shader, const [
                  'Off',
                  'Anime4K A (HQ)',
                  'Anime4K B (HQ)',
                  'Anime4K A (Fast)',
                ], (v) => _shader = v),
                help: 'Runs on your GPU; only you see it',
              ),
              _row(
                'Hardware decoding',
                _drop(_hwdec, const ['Auto', 'On', 'Off'], (v) => _hwdec = v),
              ),
              const Divider(),
              _row(
                'Subtitles',
                _drop('English · ASS', const [
                  'Off',
                  'English · ASS',
                  'Signs only',
                ], (_) {}),
              ),
              _row(
                'Subtitle size',
                SizedBox(
                  width: 140,
                  child: Slider(
                    value: _subSize,
                    min: 0.6,
                    max: 1.6,
                    onChanged: (v) => setState(() => _subSize = v),
                  ),
                ),
              ),
              _row(
                'Audio',
                _drop('Japanese', const ['Japanese', 'English'], (_) {}),
              ),
              const SizedBox(height: 4),
              const Text(
                'Track choices carry to the next episode.',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [child] only while the demo player is paused (or has nothing).
class _PausedOnly extends StatelessWidget {
  final Widget child;
  const _PausedOnly({required this.child});

  @override
  Widget build(BuildContext context) {
    final p = _demoPlayer;
    return StreamBuilder<bool>(
      stream: p?.stream.playing,
      builder: (context, _) {
        final paused = p == null || !p.state.playing;
        return AnimatedOpacity(
          duration: _easeTime,
          curve: _ease,
          opacity: paused ? 1 : 0,
          child: IgnorePointer(ignoring: !paused, child: child),
        );
      },
    );
  }
}

/// "Waiting for Alex, Mika" or "Waiting for you · press Space", with
/// their avatars; only while paused.
class _WaitingPill extends StatelessWidget {
  const _WaitingPill();

  @override
  Widget build(BuildContext context) {
    final notReady = _members.where((m) => !m.ready && !m.stale).toList();
    final meWaiting = !_me.value.ready;
    final text = meWaiting
        ? 'Waiting for you · press Space when ready'
        : notReady.isEmpty
        ? 'Paused'
        : 'Waiting for ${notReady.map((m) => m.name).join(', ')}';
    return _PausedOnly(
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
            for (final m in (meWaiting ? [_me.value] : notReady).take(4))
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _Avatar(member: m, size: 28),
              ),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
