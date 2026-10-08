import 'package:flutter/material.dart';

import 'src/screens/home/ui.dart';
import 'src/shell/app_shell.dart';

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: ThemeData.dark(),
      home: const AppShell(),
    );
  }
}
