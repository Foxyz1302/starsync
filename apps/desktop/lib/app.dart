import 'package:flutter/material.dart';

import 'src/screens/home/ui.dart';
import 'src/shell/app_shell.dart';
import 'src/widgets/app_keys.dart';
import 'src/widgets/app_menu.dart';

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      // Material's own menus (the player's track menus, sort) wear the
      // app menu's surface.
      theme: AppMenuStyle.theme(ThemeData.dark()),
      shortcuts: appShortcuts,
      home: const AppKeys(child: AppShell()),
    );
  }
}
