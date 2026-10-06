import 'package:flutter/material.dart';

import '../../state/settings.dart';
import '../../update/update_controller.dart';
import '../../widgets/window_chrome_bar.dart';
import 'about_page.dart';
import 'home_page.dart';
import 'integrations_page.dart';
import 'profile.dart';
import 'settings_page.dart';
import 'ui.dart';
import 'update_indicator.dart';

/// Everything outside a session: Home (profile, Join/Host, recents),
/// Settings, Integrations, About behind a slim rail.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Column(
        children: [
          WindowChromeBar(title: appName),
          Expanded(child: HomeShell()),
        ],
      ),
    );
  }
}

/// [HomeScreen] minus the window chrome (which needs window_manager), so
/// tests can pump it.
class HomeShell extends StatefulWidget {
  final UpdateController? updates;
  final bool autoUpdateCheck;
  const HomeShell({super.key, this.updates, this.autoUpdateCheck = true});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
    (Icons.extension_outlined, Icons.extension, 'Integrations'),
    (Icons.info_outline, Icons.info, 'About'),
  ];

  @override
  void initState() {
    super.initState();
    Profile.instance.ensureLoaded();
    if (widget.autoUpdateCheck) _autoCheck();
  }

  Future<void> _autoCheck() async {
    final s = AppSettings.instance;
    await s.ensureLoaded();
    if (s.autoCheckUpdates.peek()) await runUpdateCheck(widget.updates);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        NavigationRail(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelType: NavigationRailLabelType.none,
          minWidth: 64,
          backgroundColor: scheme.surfaceContainerLowest,
          indicatorShape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
          destinations: [
            for (final (icon, selected, label) in _destinations)
              NavigationRailDestination(
                icon: Tooltip(message: label, child: Icon(icon)),
                selectedIcon: Tooltip(message: label, child: Icon(selected)),
                label: Text(label),
              ),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              HomePage(updates: widget.updates),
              SettingsPage(updates: widget.updates),
              const IntegrationsPage(),
              AboutPage(updates: widget.updates),
            ],
          ),
        ),
      ],
    );
  }
}
