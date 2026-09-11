import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../state/session_state.dart';

const _minimalControls = MaterialDesktopVideoControlsThemeData(
  playAndPauseOnTap: false,
  keyboardShortcuts: {},
  bottomButtonBar: [
    MaterialDesktopVolumeButton(),
    _ReadyButton(),
    _MarkAllButton(),
    MaterialDesktopPositionIndicator(),
    Spacer(),
    MaterialDesktopFullscreenButton(),
  ],
);

class MinimalSessionScreen extends StatefulWidget {
  const MinimalSessionScreen({super.key});

  @override
  State<MinimalSessionScreen> createState() => _MinimalSessionScreenState();
}

class _MinimalSessionScreenState extends State<MinimalSessionScreen> {
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _video == null
                ? const Center(child: Text('player starting…'))
                : MaterialDesktopVideoControlsTheme(
                    normal: _minimalControls,
                    fullscreen: _minimalControls,
                    child: Video(controller: _video!),
                  ),
          ),
          const Positioned(
            top: 8,
            right: 8,
            child: Text('MINIMAL',
                style: TextStyle(color: Colors.red, fontSize: 12)),
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
