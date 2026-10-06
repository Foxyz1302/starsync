import 'package:flutter/material.dart';

import 'ui.dart';

class IntegrationsPage extends StatelessWidget {
  const IntegrationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return PageScroll(
      maxWidth: 680,
      children: [
        const PageTitle('Integrations',
            subtitle: 'Connect media libraries to pick what to watch.'),
        Panel(
          enabled: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.video_library_outlined, size: 32),
              const SizedBox(width: kGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Jellyfin', style: t.titleMedium),
                    const SizedBox(height: 4),
                    const Text(
                      'Coming soon: link your Jellyfin account(s), browse and '
                      'put up episodes, watched/continue-watching sync.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: kGap),
              const OutlinedButton(onPressed: null, child: Text('Link account')),
            ],
          ),
        ),
      ],
    );
  }
}
