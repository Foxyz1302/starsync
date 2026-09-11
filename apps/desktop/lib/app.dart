import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'src/screens/connect_screen.dart';
import 'src/screens/legacy_session_screen.dart';
import 'src/screens/minimal_session_screen.dart';
import 'src/screens/nosheet_session_screen.dart';
import 'src/screens/session_screen.dart';
import 'src/screens/welcome_screen.dart';
import 'src/state/session_state.dart';

bool get useLegacySession =>
    Platform.environment['SYNC_RELAY_UI'] == 'legacy';

bool get useMinimalSession =>
    Platform.environment['SYNC_RELAY_UI'] == 'minimal';

bool get useNosheetSession =>
    Platform.environment['SYNC_RELAY_UI'] == 'nosheet';

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    return MaterialApp(
      title: 'Watch Together',
      theme: ThemeData.dark(),
      home: SignalBuilder(
        builder: (context) {
          return switch (session.route.value) {
            AppRoute.welcome => const WelcomeScreen(),
            AppRoute.connect => const ConnectScreen(),
            AppRoute.session => useMinimalSession
                ? const MinimalSessionScreen()
                : useNosheetSession
                    ? const NosheetSessionScreen()
                    : useLegacySession
                        ? const LegacySessionScreen()
                        : const SessionScreen(),
          };
        },
      ),
    );
  }
}
