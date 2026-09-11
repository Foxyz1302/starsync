import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../session/health.dart';
import '../state/session_state.dart';
import '../widgets/member_avatar.dart';

const _nosheetControls = MaterialDesktopVideoControlsThemeData(
  playAndPauseOnTap: false,
  keyboardShortcuts: {},
  visibleOnMount: true,
  hideMouseOnControlsRemoval: false,
  controlsHoverDuration: Duration(hours: 24),
  bottomButtonBar: [
    MaterialDesktopVolumeButton(),
    _ReadyButton(),
    _MarkAllButton(),
    MaterialDesktopPositionIndicator(),
    Spacer(),
    MaterialDesktopFullscreenButton(),
  ],
);

class NosheetSessionScreen extends StatefulWidget {
  const NosheetSessionScreen({super.key});

  @override
  State<NosheetSessionScreen> createState() => _NosheetSessionScreenState();
}

class _NosheetSessionScreenState extends State<NosheetSessionScreen> {
  VideoController? _video;

  @override
  void initState() {
    super.initState();
    _video = VideoController(
        SessionState.instance.coordinator.playback.player);
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (SessionState.instance.route.peek() != AppRoute.session) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      SessionState.instance.coordinator.toggleReady();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _video == null
                ? const Center(child: Text('player starting…'))
                : MaterialDesktopVideoControlsTheme(
                    normal: _nosheetControls,
                    fullscreen: _nosheetControls,
                    child: Video(controller: _video!),
                  ),
          ),
          const Positioned(
            top: 8,
            right: 8,
            child: Text('NOSHEET',
                style: TextStyle(color: Colors.red, fontSize: 12)),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: SignalBuilder(builder: (context) {
              final h = coord.health.value;
              final starve = coord.starving.value;
              final retrying = coord.reconnecting.value;
              final unwell = h.severity == HealthSeverity.warn ||
                  h.severity == HealthSeverity.error ||
                  retrying ||
                  starve != null;
              if (!unwell) return const SizedBox.shrink();
              return Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(999),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  [h.message, if (starve != null) starve].join(' · '),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              );
            }),
          ),
          SignalBuilder(builder: (context) {
            final r = coord.room.value;
            if (r == null || r.transport != 'held') {
              return const SizedBox.shrink();
            }
            final waiting = [
              for (final m in r.members)
                if (!m.ready) m
            ];
            if (waiting.isEmpty) return const SizedBox.shrink();
            return Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Wrap(
                    spacing: -20,
                    children: [
                      for (final m in waiting)
                        Opacity(
                          opacity: m.stale ? 0.5 : 1.0,
                          child: MemberAvatar(
                            avatarBase64: m.avatar,
                            name: m.name,
                            size: 64,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          Positioned(
            right: 12,
            top: 56,
            child: SignalBuilder(builder: (context) {
              final items = coord.toasts.value;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final t in items.reversed.take(5))
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Text(t.text),
                      ),
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _ReadyButton extends StatelessWidget {
  const _ReadyButton();

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final ready = SessionState
                .instance.coordinator.selfMember.value?.ready ??
            false;
        return TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () =>
              SessionState.instance.coordinator.toggleReady(),
          child: Text(ready ? 'Ready ✓' : 'Not ready',
              style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }
}

class _MarkAllButton extends StatelessWidget {
  const _MarkAllButton();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () =>
          SessionState.instance.coordinator.forcePlayAll(),
      child: const Text('Mark everyone ready',
          style: TextStyle(fontSize: 12)),
    );
  }
}
