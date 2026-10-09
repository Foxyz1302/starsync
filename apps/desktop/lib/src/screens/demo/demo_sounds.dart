part of 'shell_demo.dart';

// DEBUG ONLY: every app sound, playable, with where it plays. The sounds
// are synthesized (lib/src/sfx/sound_bank.dart); edit a spec, hot reload,
// press "Re-render" and play it again.

typedef _Sound = ({String key, String name, String where, SoundSpec spec, bool proposal});

List<(String, List<_Sound>)> _soundGroups() {
  _Sound k(SfxKind kind, String name, String where) =>
      (key: kind.name, name: name, where: where, spec: soundFor(kind), proposal: false);
  _Sound x(ExtraSound s, String name, String where) =>
      (key: 'x-${s.name}', name: name, where: where, spec: extraSound(s), proposal: true);
  return [
    ('Ready', [
      k(SfxKind.ready, 'Ready', 'Someone presses Space (you too). The second note climbs with each ready person: try the ladder below'),
      k(SfxKind.unready, 'Not ready', 'Someone takes their ready back, or idle auto-unready'),
      k(SfxKind.forceReady, 'Everyone ready', '"Mark everyone ready" from the member list or the player'),
      k(SfxKind.forceUnready, 'Made not ready', 'Someone sets another member not ready'),
      x(ExtraSound.start, 'Starting', 'Everyone is ready and playback starts together'),
    ]),
    ('People', [
      k(SfxKind.join, 'Joined', 'Someone joins the server'),
      k(SfxKind.leave, 'Left', 'Someone leaves (a little quieter than join)'),
      k(SfxKind.stale, 'Lagging', 'Someone stops reporting for a few seconds (bad connection)'),
      k(SfxKind.kick, 'Removed', 'Someone is kicked; also when it is you'),
    ]),
    ('Playback', [
      k(SfxKind.swap, 'New video', 'Someone puts up a different video or episode'),
      k(SfxKind.forcePlay, 'Forced play', 'Someone starts playback without waiting for everyone'),
      k(SfxKind.forceHold, 'Held', 'Someone holds playback for everyone'),
      k(SfxKind.pause, 'Paused', 'Playback pauses (someone unready, buffering)'),
      k(SfxKind.resume, 'Resumed', 'Playback resumes after a pause'),
      k(SfxKind.seek, 'Seek', 'Someone seeks or skips (off by default: seeks are frequent)'),
      x(ExtraSound.finished, 'Finished', 'The video reaches its end'),
    ]),
    ('Chat & alerts', [
      k(SfxKind.chat, 'Message', 'A chat message from someone else'),
      x(ExtraSound.mention, 'Mention', 'A message with your name in it'),
      x(ExtraSound.image, 'Image', 'Someone sends an image to chat'),
      k(SfxKind.warn, 'Idle warning', '"Auto-unready in 2 min unless you press Space"'),
      x(ExtraSound.lost, 'Connection lost', 'The server stops answering; reconnecting'),
      x(ExtraSound.back, 'Reconnected', 'Back in the server after a drop'),
    ]),
  ];
}

class _SoundBoard extends StatefulWidget {
  const _SoundBoard();

  @override
  State<_SoundBoard> createState() => _SoundBoardState();
}

class _SoundBoardState extends State<_SoundBoard> {
  static final _sfx = SynthSfx();
  final _off = <String>{'seek'};
  String? _playing;
  bool _sequence = false;

  Future<void> _play(String key, SoundSpec spec) async {
    setState(() => _playing = key);
    await _sfx.playSpec(key, spec);
    final ms = (spec.length * 1000).round();
    await Future<void>.delayed(Duration(milliseconds: ms));
    if (mounted && _playing == key) setState(() => _playing = null);
  }

  Future<void> _playAll() async {
    setState(() => _sequence = true);
    for (final (_, sounds) in _soundGroups()) {
      for (final s in sounds) {
        if (!mounted || !_sequence) return;
        await _play(s.key, s.spec);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (mounted) setState(() => _sequence = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final pct = (_sfx.volume * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panel(context, 'Sounds', [
          Row(
            children: [
              Icon(_sfx.volume == 0 ? Icons.volume_off_outlined : Icons.volume_down_outlined,
                  color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: _sfx.volume,
                  onChanged: (v) => setState(() => _sfx.volume = v),
                  onChangeEnd: (_) => _play('ready', soundFor(SfxKind.ready)),
                ),
              ),
              SizedBox(width: 44, child: Text('$pct%', textAlign: TextAlign.end)),
            ],
          ),
          Text('Soft and short on purpose; the slider previews the ready chime when you let go.', style: muted),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: _sequence ? () => setState(() => _sequence = false) : _playAll,
                icon: Icon(_sequence ? Icons.stop : Icons.playlist_play),
                label: Text(_sequence ? 'Stop' : 'Play all in order'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _sfx.forget();
                  _Waveform._cache.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Re-render (after hot reload)'),
              ),
              const SizedBox(width: 8),
              Text('Ready ladder:', style: muted),
              for (var i = 1; i <= 6; i++)
                ActionChip(
                  label: Text('$i'),
                  tooltip: '$i${i == 1 ? 'st' : i == 2 ? 'nd' : i == 3 ? 'rd' : 'th'} person ready',
                  onPressed: () => _play('ready-$i', readySound(i)),
                ),
            ],
          ),
        ]),
        for (final (title, sounds) in _soundGroups())
          _panel(context, title, [
            for (final s in sounds) _row(context, s),
          ]),
      ],
    );
  }

  Widget _panel(BuildContext context, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                ...children,
              ],
            ),
          ),
        ),
      );

  Widget _row(BuildContext context, _Sound s) {
    final scheme = Theme.of(context).colorScheme;
    final on = !_off.contains(s.key);
    final playing = _playing == s.key;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          IconButton.filledTonal(
            tooltip: 'Play',
            onPressed: () => _play(s.key, s.spec),
            icon: Icon(playing ? Icons.graphic_eq : Icons.play_arrow_rounded),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (s.proposal) ...[
                      const SizedBox(width: 8),
                      _Pill('new', scheme.tertiary),
                    ],
                  ],
                ),
                Text(s.where, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            height: 32,
            child: _Waveform(id: s.key, spec: s.spec, playing: playing, color: on ? scheme.primary : scheme.outlineVariant),
          ),
          Switch(
            value: on,
            onChanged: (v) => setState(() => v ? _off.remove(s.key) : _off.add(s.key)),
          ),
        ],
      ),
    );
  }
}

/// The sound's envelope (peak per column), drawn once per spec.
class _Waveform extends StatelessWidget {
  final String id;
  final SoundSpec spec;
  final bool playing;
  final Color color;
  const _Waveform({required this.id, required this.spec, required this.playing, required this.color});

  static final _cache = <String, List<double>>{};

  List<double> _peaks() => _cache[id] ??= () {
        final samples = render(spec);
        const cols = 48;
        final per = (samples.length / cols).ceil();
        final peaks = <double>[];
        var max = 0.0;
        for (var c = 0; c < cols; c++) {
          var p = 0.0;
          for (var i = c * per; i < (c + 1) * per && i < samples.length; i++) {
            p = math.max(p, samples[i].abs());
          }
          peaks.add(p);
          max = math.max(max, p);
        }
        return [for (final p in peaks) max == 0 ? 0.0 : math.sqrt(p / max)];
      }();

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        duration: _easeTime,
        curve: _ease,
        opacity: playing ? 1 : 0.55,
        child: CustomPaint(painter: _WavePainter(_peaks(), color)),
      );
}

class _WavePainter extends CustomPainter {
  final List<double> peaks;
  final Color color;
  _WavePainter(this.peaks, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final step = size.width / peaks.length;
    final mid = size.height / 2;
    for (var i = 0; i < peaks.length; i++) {
      final h = math.max(1.0, peaks[i] * mid);
      final x = step * (i + 0.5);
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.peaks != peaks || old.color != color;
}
