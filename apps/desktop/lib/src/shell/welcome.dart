import 'package:flutter/material.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/sign_in_panel.dart';
import '../screens/home/ui.dart' show appName;
import 'motion.dart';

/// One line under the app name.
const appTagline = 'Watch together, in sync';

/// Window width from which the welcome band puts the three ways beside
/// the app name (else under it).
const welcomeWideFrom = 980.0;

/// Top of the Library while not in a server: the app's name and the three
/// ways in, Join a friend first (what most people came for), then Host and
/// Watch solo. None of them needs Jellyfin.
class WelcomeBand extends StatelessWidget {
  final VoidCallback onJoin;
  final VoidCallback onHost;
  final VoidCallback onSolo;
  final VoidCallback? onDismiss;
  const WelcomeBand({super.key, required this.onJoin, required this.onHost, required this.onSolo, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final hero = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset('assets/icon/icon_256.png', width: 52, height: 52, filterQuality: FilterQuality.medium),
        ),
        const SizedBox(width: 14),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(appName, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.1)),
            const SizedBox(height: 2),
            Text(appTagline, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (onDismiss != null)
              TextButton(
                key: const ValueKey('welcome-dismiss'),
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: scheme.onSurfaceVariant,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text("Don't show again"),
              ),
          ],
        ),
      ],
    );
    final ways = [
      WayCard(
        key: const ValueKey('way-join'),
        icon: Icons.login_rounded,
        title: 'Join a friend',
        caption: 'Got an address from a friend? Join with it. Nothing to set up.',
        primary: true,
        onTap: onJoin,
      ),
      WayCard(
        key: const ValueKey('way-host'),
        icon: Icons.podcasts_rounded,
        title: 'Host',
        caption: 'You have the video. Friends join you and watch it with you.',
        onTap: onHost,
      ),
      WayCard(
        key: const ValueKey('way-solo'),
        icon: Icons.person_outline_rounded,
        title: 'Watch solo',
        caption: 'Just you: play anything below. Invite friends any time.',
        onTap: onSolo,
      ),
    ];
    Widget row(List<Widget> cards) => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, c) in cards.indexed) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: c)],
            ],
          ),
        );
    final band = Container(
      key: const ValueKey('welcome-band'),
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary.withValues(alpha: 0.16), scheme.primary.withValues(alpha: 0.03)],
        ),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= welcomeWideFrom - 40) {
          return Row(
            children: [
              Padding(padding: const EdgeInsets.only(left: 4, right: 20), child: hero),
              Expanded(child: row(ways)),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(left: 4, bottom: 12), child: hero),
            if (box.maxWidth >= 520)
              row(ways)
            else
              for (final (i, c) in ways.indexed) ...[if (i > 0) const SizedBox(height: 8), c],
          ],
        );
      }),
    );
    return band;
  }
}

/// One way in: a tinted icon, a title and a one-line caption.
class WayCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String caption;
  final bool primary;
  final VoidCallback onTap;
  const WayCard({
    super.key,
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
    this.primary = false,
  });

  @override
  State<WayCard> createState() => _WayCardState();
}

class _WayCardState extends State<WayCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = widget.primary;
    final bg = primary ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final fg = primary ? scheme.onPrimaryContainer : scheme.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        duration: easeTime,
        curve: ease,
        scale: _hover ? 1.015 : 1,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: primary ? scheme.primary : scheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(widget.icon, size: 20, color: primary ? scheme.onPrimary : scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
                        const SizedBox(height: 2),
                        Text(widget.caption,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, height: 1.3, color: fg.withValues(alpha: 0.72))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Library's Jellyfin source with no server linked: what plays with
/// nothing set up (Files, Link), then Jellyfin as an optional extra that
/// guests never need. The sign-in opens in place.
class NoJellyfinPanel extends StatefulWidget {
  final JellyfinAccounts accounts;
  final VoidCallback onFiles;
  final VoidCallback onLink;
  const NoJellyfinPanel({super.key, required this.accounts, required this.onFiles, required this.onLink});

  @override
  State<NoJellyfinPanel> createState() => _NoJellyfinPanelState();
}

class _NoJellyfinPanelState extends State<NoJellyfinPanel> {
  bool _signIn = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final sources = [
      WayCard(
        key: const ValueKey('source-files'),
        icon: Icons.folder_outlined,
        title: 'Files',
        caption: 'Videos on this computer. Drop a file or folder anywhere.',
        onTap: widget.onFiles,
      ),
      WayCard(
        key: const ValueKey('source-link'),
        icon: Icons.link,
        title: 'Link',
        caption: 'YouTube, X, or any video address. Ctrl+V anywhere.',
        onTap: widget.onLink,
      ),
    ];
    return SingleChildScrollView(
      key: const ValueKey('media-jellyfin'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pick something to watch', style: t.titleMedium),
              const SizedBox(height: 4),
              Text('No account needed: these work for everyone.', style: muted),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, box) => box.maxWidth < 460
                    ? Column(children: [sources[0], const SizedBox(height: 8), sources[1]])
                    : IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: sources[0]),
                            const SizedBox(width: 10),
                            Expanded(child: sources[1]),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 20),
              Material(
                key: const ValueKey('jellyfin-optional'),
                color: scheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                ),
                clipBehavior: Clip.antiAlias,
                child: AnimatedSize(
                  duration: easeTime,
                  curve: ease,
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.video_library_outlined, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                    const Text('Jellyfin', style: TextStyle(fontWeight: FontWeight.w600)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: scheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text('optional', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                                    ),
                                  ]),
                                  Text(
                                    'Only if you have a Jellyfin server: browse it here, '
                                    'with progress and next episodes. Joining a friend never needs it.',
                                    style: muted.copyWith(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (!_signIn)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: const ValueKey('jellyfin-link'),
                              onPressed: () => setState(() => _signIn = true),
                              child: const Text('Link a server'),
                            ),
                          ),
                        if (_signIn) ...[
                          const SizedBox(height: 14),
                          JellyfinSignInPanel(accounts: widget.accounts, onCancel: () => setState(() => _signIn = false)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
