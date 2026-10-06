import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import 'src/screens/home/home_screen.dart';
import 'src/screens/home/ui.dart';
import 'src/screens/session_screen.dart';
import 'src/state/session_state.dart';

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    return MaterialApp(
      title: appName,
      theme: ThemeData.dark(),
      home: SignalBuilder(
        builder: (context) {
          return switch (session.route.value) {
            AppRoute.home => const HomeScreen(),
            AppRoute.session => const SessionScreen(),
          };
        },
      ),
    );
  }
}
