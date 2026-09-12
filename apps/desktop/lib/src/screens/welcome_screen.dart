import 'package:flutter/material.dart';

import '../state/session_state.dart';
import '../update/updater.dart';
import '../widgets/window_chrome_bar.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Column(
        children: [
          WindowChromeBar(title: 'Watch Together'),
          Expanded(child: _WelcomeBody()),
        ],
      ),
    );
  }
}

class _WelcomeBody extends StatelessWidget {
  const _WelcomeBody();

  @override
  Widget build(BuildContext context) {
    final session = SessionState.instance;
    return Center(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Watch Together', style: TextStyle(fontSize: 24)),
              Text('v$appVersion', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              const Text(
                'Set your name + avatar on the next screen.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => session.goConnect(ConnectMode.host),
                    child: const Text('Host'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () => session.goConnect(ConnectMode.join),
                    child: const Text('Join'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Host opens ports and serves. Clients open nothing.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
  }
}
