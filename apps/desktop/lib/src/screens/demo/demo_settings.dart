part of 'shell_demo.dart';

// DEBUG ONLY: the Settings tab. App-wide things only; everything about
// the player lives behind the gear in the player (pointer card at the top
// of every page). Controls are placeholders that hold their own state.

class _SettingsTab extends StatefulWidget {
  final VoidCallback onOpenPlayerSettings;
  const _SettingsTab({required this.onOpenPlayerSettings});

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  static const _sections = [
    (Icons.person_outline, 'Profile'),
    (Icons.hub_outlined, 'Party & network'),
    (Icons.extension_outlined, 'Jellyfin & integrations'),
    (Icons.notifications_none, 'Notifications & sounds'),
    (Icons.palette_outlined, 'Appearance'),
    (Icons.system_update_alt, 'Updates'),
    (Icons.info_outline, 'About'),
  ];
  int _at = 0;
  final _bools = <String, bool>{
    'toast-chat': true,
    'toast-ready': true,
    'toast-seek': false,
    'unfocused': true,
    'sounds': true,
    'reduce-motion': false,
    'auto-update': true,
    'auto-next': true,
    'remember-folders': true,
  };

  Widget _switch(String key, String title, [String? help]) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: help == null ? null : Text(help),
    value: _bools[key]!,
    onChanged: (v) => setState(() => _bools[key] = v),
  );

  // Material, not a coloured box: list tiles paint their ripple on it.
  Widget _card(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    ),
  );

  List<Widget> _page() {
    final scheme = Theme.of(context).colorScheme;
    switch (_at) {
      case 0:
        return [
          _card('You', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _Avatar(member: _me.value, size: 48, badges: false),
              title: Text(_me.value.name),
              subtitle: const Text(
                'Name, picture and colour: click your avatar in the top left',
              ),
            ),
          ]),
        ];
      case 1:
        return [
          _card('Hosting', [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Default port'),
              trailing: Text('8080'),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Password'),
              subtitle: Text(
                'Asked when you host; blank = anyone who reaches the port can join',
              ),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Relay buffer'),
              subtitle: Text('Memory the server keeps for relayed videos'),
              trailing: Text('256 MB ahead · 64 MB back'),
            ),
          ]),
          _card('Recent servers', [
            for (final s in [
              'VPS · vps.example:8080',
              'Bob · 192.168.1.20:8080',
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(s),
                trailing: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.close, size: 18),
                ),
              ),
          ]),
        ];
      case 2:
        return [
          _card('Jellyfin', [
            for (final (name, user) in [
              ('Example Jellyfin', 'foxyz'),
              ('Bob\'s box', 'guest'),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.video_library_outlined),
                title: Text(name),
                subtitle: Text('signed in as $user'),
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('Sign out'),
                ),
              ),
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.add),
              label: const Text('Add a Jellyfin server'),
            ),
          ]),
          _card('AnimeFlow', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.downloading_outlined),
              title: const Text('anime.example.org'),
              subtitle: const Text(
                'Uses your Example Jellyfin sign-in · can view, request, approve',
              ),
              trailing: _Pill('connected', Colors.greenAccent.shade400),
            ),
            Text(
              'Powers the Schedule tab: what is downloaded, downloading or missing, and requests.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ]),
          _card('Local files', [
            _switch(
              'remember-folders',
              'Remember folders',
              'Folders added in Files stay between launches',
            ),
          ]),
        ];
      case 3:
        return [
          _card('Pop-ups', [
            _switch('toast-chat', 'Chat messages'),
            _switch('toast-ready', 'Ready / joined / left'),
            _switch(
              'toast-seek',
              'Seeks and skips',
              'Always in the activity log',
            ),
            _switch(
              'unfocused',
              'Desktop notification when the app is in the background',
            ),
          ]),
          _card('Sounds', [
            _switch(
              'sounds',
              'Play sounds',
              'Soft cues for ready, join and chat; seeks stay silent',
            ),
          ]),
        ];
      case 4:
        return [
          _card('Look', [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Theme'),
              trailing: Text('Dark'),
            ),
            _switch(
              'reduce-motion',
              'Reduce motion',
              'Fades instead of slides, no spreading avatars',
            ),
          ]),
          _card('Playback', [
            _switch(
              'auto-next',
              'Play the next episode automatically',
              '10 s countdown at the end',
            ),
          ]),
        ];
      case 5:
        return [
          _card('Updates', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Watch together 0.2.2'),
              subtitle: const Text('0.3.0 is available'),
              trailing: FilledButton(
                onPressed: () {},
                child: const Text('Update and restart'),
              ),
            ),
            _switch('auto-update', 'Check for updates on launch'),
          ]),
        ];
      default:
        return [
          _card('About', [
            const Text(
              'Watch together for friends: synced playback, Jellyfin, relay.',
            ),
            const SizedBox(height: 8),
            Text(
              'mpv · media_kit · Flutter',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ]),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pointer = Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.tune, color: scheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Player design, shaders, subtitles and audio live in the player: the ⚙ in its controls.',
            ),
          ),
          TextButton(
            onPressed: widget.onOpenPlayerSettings,
            child: const Text('Open player settings'),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 760;
        final nav = narrow
            ? SizedBox(
                height: 52,
                child: _HScroll(
                  builder: (c) => ListView(
                    controller: c,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    children: [
                      for (var i = 0; i < _sections.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(_sections[i].$2),
                            selected: _at == i,
                            onSelected: (_) => setState(() => _at = i),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            : SizedBox(
                width: 250,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 8, 20),
                  children: [
                    for (var i = 0; i < _sections.length; i++)
                      ListTile(
                        selected: _at == i,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(_sections[i].$1, size: 20),
                        title: Text(_sections[i].$2),
                        onTap: () => setState(() => _at = i),
                      ),
                  ],
                ),
              );
        final page = _fadeSwitch(
          KeyedSubtree(
            key: ValueKey(_at),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 24, 24),
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _sections[_at].$2,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 14),
                        pointer,
                        ..._page(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        return narrow
            ? Column(
                children: [
                  nav,
                  Expanded(child: page),
                ],
              )
            : Row(
                children: [
                  nav,
                  Expanded(child: page),
                ],
              );
      },
    );
  }
}
