import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/session_state.dart';
import '../../state/settings.dart';
import '../../update/update_controller.dart';
import 'about_page.dart';
import 'connect_flow.dart';
import 'health_probe.dart';
import 'host_tab.dart';
import 'integrations_page.dart';
import 'join_tab.dart';
import 'profile.dart';
import 'settings_page.dart';
import 'top_bar.dart';
import 'update_indicator.dart';

/// Everything outside a session: one top bar (profile, Join/Host tabs,
/// Settings/Integrations/About, window buttons) over a full-width body.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: HomeShell(windowControls: true));
  }
}

/// [HomeScreen]'s content. Tests pump it with [windowControls] off (the
/// drag area and window buttons need window_manager) and a fake [healthGet].
class HomeShell extends StatefulWidget {
  final UpdateController? updates;
  final bool autoUpdateCheck;
  final bool windowControls;
  final HealthGetter healthGet;
  const HomeShell({
    super.key,
    this.updates,
    this.autoUpdateCheck = true,
    this.windowControls = false,
    this.healthGet = defaultHealthGet,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  HomeView _view = HomeView.join;
  final _flow = ConnectFlow();
  late final _join = JoinFields(SessionState.instance.lastForm);
  late final _host = HostFields(SessionState.instance.lastForm);
  late final void Function() _stopKickWatch;
  late final void Function() _stopCrashWatch;
  bool _dialogOpen = false;
  String? _lastKickShown;

  @override
  void initState() {
    super.initState();
    Profile.instance.ensureLoaded();
    if (widget.autoUpdateCheck) _autoCheck();
    _flow.onKicked = _showKickedDialog;
    // Back from a session that ended in a kick: say so.
    _stopKickWatch = effect(() {
      final kick = SessionState.instance.coordinator.kickReason.value;
      if (kick == null || kick.isEmpty) {
        _lastKickShown = null;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _showKickedDialog(kick));
    });
    // Back from a session whose hosted server crashed: say so on the Host tab.
    _stopCrashWatch = effect(() {
      final crash = SessionState.instance.serverCrash.value;
      if (crash == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SessionState.instance.serverCrash.value = null;
        if (!mounted) return;
        _flow.showError(ConnectMode.host, CardError('Server crashed', crash));
        setState(() => _view = HomeView.host);
      });
    });
  }

  @override
  void dispose() {
    _stopKickWatch();
    _stopCrashWatch();
    _flow.dispose();
    _join.dispose();
    _host.dispose();
    super.dispose();
  }

  Future<void> _autoCheck() async {
    final s = AppSettings.instance;
    await s.ensureLoaded();
    if (s.autoCheckUpdates.peek()) await runUpdateCheck(widget.updates);
  }

  Future<void> _showKickedDialog(String reason) async {
    if (!mounted || _dialogOpen || reason == _lastKickShown) return;
    _lastKickShown = reason;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('You were removed'),
          content: Text(reason.isEmpty ? 'The host removed you from the server.' : reason),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  void _select(HomeView v) => setState(() => _view = v);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only the visible view is mounted: the Join tab polls /health only
    // while shown. Form state lives here, so nothing is lost on switch.
    final body = switch (_view) {
      HomeView.join =>
        JoinTab(flow: _flow, fields: _join, healthGet: widget.healthGet),
      HomeView.host => HostTab(
          flow: _flow,
          fields: _host,
          onOpenIntegrations: () => _select(HomeView.integrations),
        ),
      HomeView.settings => SettingsPage(updates: widget.updates),
      HomeView.integrations => const IntegrationsPage(),
      HomeView.about => AboutPage(updates: widget.updates),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            _select(HomeView.join),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            _select(HomeView.host),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            _select(HomeView.settings),
      },
      child: FocusScope(
        autofocus: true,
        child: Column(
          children: [
            HomeTopBar(
              view: _view,
              onSelect: _select,
              updates: widget.updates,
              windowControls: widget.windowControls,
            ),
            Divider(height: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            Expanded(
              child: KeyedSubtree(key: ValueKey(_view), child: body),
            ),
          ],
        ),
      ),
    );
  }
}
