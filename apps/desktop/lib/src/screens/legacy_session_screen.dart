import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../state/session_state.dart';

const _legacyControls = MaterialDesktopVideoControlsThemeData(
  playAndPauseOnTap: false,
  keyboardShortcuts: {},
  bottomButtonBar: [
    MaterialDesktopVolumeButton(),
    MaterialDesktopPositionIndicator(),
    Spacer(),
    MaterialDesktopFullscreenButton(),
  ],
);

class LegacySessionScreen extends StatefulWidget {
  const LegacySessionScreen({super.key});

  @override
  State<LegacySessionScreen> createState() => _LegacySessionScreenState();
}

class _LegacySessionScreenState extends State<LegacySessionScreen> {
  VideoController? _video;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _video = VideoController(
        SessionState.instance.coordinator.playback.player);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      SessionState.instance.coordinator.toggleReady();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    final coord = session.coordinator;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          title: SignalBuilder(
            builder: (context) {
              final h = coord.health.value;
              final r = coord.room.value;
              return Text('Room · ${r?.transport ?? '…'} · ${h.message}');
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => session.leave(),
            ),
          ],
        ),
        body: Column(
          children: [
            SignalBuilder(builder: (context) {
              final h = coord.health.value;
              final starve = coord.starving.value;
              final text = [
                h.message,
                if (starve != null) starve,
              ].join(' · ');
              return Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(text),
              );
            }),
            Expanded(
              child: _video == null
                  ? const Center(child: Text('player starting…'))
                  : MaterialDesktopVideoControlsTheme(
                      normal: _legacyControls,
                      fullscreen: _legacyControls,
                      child: Video(controller: _video!),
                    ),
            ),
            SignalBuilder(builder: (context) {
              final r = coord.room.value;
              if (r == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final m in r.members)
                      Chip(
                        avatar: CircleAvatar(
                          child: Text(m.name.isEmpty
                              ? '?'
                              : m.name[0].toUpperCase()),
                        ),
                        label: Text(m.name),
                        backgroundColor: m.ready
                            ? Colors.green.withValues(alpha: 0.3)
                            : null,
                      ),
                  ],
                ),
              );
            }),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SignalBuilder(builder: (context) {
                    final ready =
                        coord.selfMember.value?.ready ?? false;
                    return ElevatedButton(
                      onPressed: () => coord.toggleReady(),
                      child: Text(ready ? 'Ready ✓' : 'Not ready'),
                    );
                  }),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => coord.forcePlayAll(),
                    child: const Text('Force play all'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
