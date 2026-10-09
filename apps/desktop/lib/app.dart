import 'package:flutter/material.dart';

import 'src/screens/home/ui.dart';
import 'src/shell/app_shell.dart';
import 'src/widgets/app_keys.dart';

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: const AppKeys(child: AppShell()),
    );
  }
}
