import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName, displayVersion, shortVersion;
import '../session/delivery.dart';
import '../session/party.dart';
import '../state/session_state.dart';
import '../widgets/app_keys.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import '../widgets/window_buttons.dart';
import 'avatar.dart';
import 'delivery_line.dart';
import 'motion.dart';

/// The shell's tabs, in strip order.
enum ShellTab {
  library('Library'),
  schedule('Schedule'),
  settings('Settings');

  final String label;
  const ShellTab(this.label);
}

const partyStripHeight = 60.0;

/// Every avatar in the strip, yours and the party's.
const stripAvatarSize = 42.0;

/// Below this window width the strip shows 3 avatars and no server text,
/// so the tabs keep their room.
const stripCompactBelow = 1100.0;

/// The 60 px strip over everything: your avatar (profile), the tabs, and
/// the party: offline Join a friend / Host, solo a "Solo" chip, Invite
/// friends and Stop, online the avatars (members card), server and
/// readiness, chat and Leave. Empty space drags the window.
class PartyStrip extends StatelessWidget {
  final ShellTab tab;
  final ValueChanged<ShellTab> onTab;
  final bool chatOpen;
  final int unread;
  final VoidCallback onChat;
  final VoidCallback onJoin;
  final VoidCallback onHost;
  final VoidCallback onLeave;
  final VoidCallback onProfile;
  /// Solo: host from here, keeping what plays.
  final VoidCallback? onInvite;

  /// Online with something up but the player closed: brings it back.
  final VoidCallback? onShowPlayer;

  /// Off in tests: the drag area and window buttons need window_manager.
  final bool windowControls;
  const PartyStrip({
    super.key,
    required this.tab,
    required this.onTab,
    required this.chatOpen,
    required this.unread,
    required this.onChat,
    required this.onJoin,
    required this.onHost,
    required this.onLeave,
    required this.onProfile,
    this.onInvite,
    this.onShowPlayer,
    this.windowControls = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < stripCompactBelow;
    final row = SignalBuilder(
      builder: (context) {
        final session = SessionState.instance;
        final coord = session.coordinator;
        final online = session.route.value == AppRoute.session;
        final solo = online && (session.solo.value || session.switching.value);
        final self = online ? coord.selfMember.value : null;
        return Row(
          children: [
            const SizedBox(width: 16),
            Tooltip(
              message: 'Your profile',
              child: InkWell(
                key: const ValueKey('strip-profile'),
                canRequestFocus: false,
                customBorder: const CircleBorder(),
                onTap: onProfile,
                child: StatusAvatar(
                  info: selfAvatarInfo(
                    ready: self?.ready ?? false,
                    host: online && !solo && coord.hostFile != null,
                    error: online ? coord.playerError.value : '',
                  ),
                  size: stripAvatarSize,
                  ring: online,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: HScroll(
                  builder: (c) => SingleChildScrollView(
                    controller: c,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in ShellTab.values)
                          StripTab(
                            key: ValueKey('tab-${t.name}'),
                            label: t.label,
                            selected: t == tab,
                            compact: compact,
                            // The version: always in sight under Settings,
                            // the full one a rest of the mouse away.
                            tooltip: t == ShellTab.settings ? '$appName ${displayVersion()}' : null,
                            caption: t == ShellTab.settings ? shortVersion() : null,
                            onTap: () => onTab(t),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (online && onShowPlayer != null)
              IconButton(
                key: const ValueKey('show-player'),
                tooltip: 'Show the player',
                onPressed: onShowPlayer,
                icon: const Icon(Icons.smart_display_outlined, size: 20),
              ),
            if (solo) ...[
              _SoloChip(compact: compact, busy: session.switching.value),
              const SizedBox(width: 10),
              if (compact)
                FilledButton(
                  key: const ValueKey('strip-invite'),
                  onPressed: session.switching.value ? null : onInvite,
                  child: const Text('Invite'),
                )
              else
                FilledButton.icon(
                  key: const ValueKey('strip-invite'),
                  onPressed: session.switching.value ? null : onInvite,
                  icon: const Icon(Icons.group_add_outlined, size: 18),
                  label: const Text('Invite friends'),
                ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('strip-leave'),
                onPressed: session.switching.value ? null : onLeave,
                child: const Text('Stop'),
              ),
            ] else if (online) ...[
              PartyWatch(
                builder: (context) => AvatarStack(
                  key: const ValueKey('party-avatars'),
                  members: partyAvatars(coord),
                  shown: compact ? 3 : 5,
                  size: stripAvatarSize,
                  onTap: () => showMembersCard(context),
                ),
              ),
              const SizedBox(width: 10),
              if (!compact) _ServerLabel(scheme: scheme),
              const SizedBox(width: 6),
              // Tab toggles the chat while the strip is shown.
              ChatKey(
                onToggle: onChat,
                child: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: IconButton(
                    key: const ValueKey('strip-chat'),
                    tooltip: 'Chat & activity (Tab)',
                    isSelected: chatOpen,
                    onPressed: onChat,
                    icon: const Icon(Icons.chat_bubble_outline, size: 20),
                    selectedIcon: Icon(
                      Icons.chat_bubble,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              OutlinedButton(
                key: const ValueKey('strip-leave'),
                onPressed: onLeave,
                child: const Text('Leave'),
              ),
            ] else ...[
              if (!compact) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: scheme.outline, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text('Offline', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 12),
              ],
              if (compact) ...[
                FilledButton(key: const ValueKey('strip-join'), onPressed: onJoin, child: const Text('Join')),
                const SizedBox(width: 8),
                FilledButton.tonal(key: const ValueKey('strip-host'), onPressed: onHost, child: const Text('Host')),
              ] else ...[
                FilledButton.icon(
                  key: const ValueKey('strip-join'),
                  onPressed: onJoin,
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('Join a friend'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  key: const ValueKey('strip-host'),
                  onPressed: onHost,
                  icon: const Icon(Icons.podcasts_rounded, size: 18),
                  label: const Text('Host'),
                ),
              ],
            ],
            const SizedBox(width: 8),
            if (windowControls) ...[
              SizedBox(
                height: 20,
                child: VerticalDivider(width: 12, color: scheme.outlineVariant),
              ),
              const WindowButtons(),
            ] else
              const SizedBox(width: 8),
          ],
        );
      },
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: SizedBox(
        height: partyStripHeight,
        child: Stack(
          children: [
            // Empty strip space drags the window; the controls on top take
            // their own clicks.
            if (windowControls)
              const Positioned.fill(
                child: WindowDragArea(child: SizedBox.expand()),
              ),
            Positioned.fill(child: row),
          ],
        ),
      ),
    );
  }
}

/// Server name and "ready n/m".
class _ServerLabel extends StatelessWidget {
  final ColorScheme scheme;
  const _ServerLabel({required this.scheme});

  @override
  Widget build(BuildContext context) => SignalBuilder(
    builder: (context) {
      final coord = SessionState.instance.coordinator;
      final r = coord.serverState.value;
      // The ready counter counts who the presence policy counts (not away,
      // not gone, able to play it).
      final counted = (r?.members ?? const <MemberView>[]).where(countsForReady).toList();
      final ready = counted.where((m) => m.ready).length;
      final stale = coord.stateStale.value;
      return Column(
        key: const ValueKey('server-label'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            serverName(),
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.1),
          ),
          Text(
            r == null
                ? 'connecting…'
                : stale
                    ? 'reconnecting…'
                    : 'ready $ready/${counted.length}',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ],
      );
    },
  );
}

/// "Solo" alone, "Your server" when hosting, else the joined server's
/// name (its `--name`), or its address while unknown.
String serverName() {
  final session = SessionState.instance;
  if (session.solo.value) return 'Solo';
  if (session.coordinator.hostFile != null) return 'Your server';
  final label = session.serverLabel.value;
  return label.isNotEmpty ? label : session.lastForm.host;
}

/// Solo: just you, on your own; a spinner while it becomes a server.
class _SoloChip extends StatelessWidget {
  final bool compact;
  final bool busy;
  const _SoloChip({required this.compact, required this.busy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: busy
          ? 'Starting your server…'
          : 'Watching on your own. Nobody can join until you invite friends.',
      child: Container(
        key: const ValueKey('solo-chip'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(Icons.person_outline_rounded, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(busy ? 'Inviting…' : 'Solo', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (!compact && !busy) ...[
              const SizedBox(width: 6),
              Text('only you', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// One strip tab: label and an underline that grows in when selected.
class StripTab extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  /// Shown after resting on the tab.
  final String? tooltip;
  /// Small text under the tab (the version under Settings).
  final String? caption;
  const StripTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.tooltip,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tab = Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
          child: SizedBox(
            height: partyStripHeight,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 3),
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedContainer(
                      duration: easeTime,
                      curve: ease,
                      height: 3,
                      width: selected ? 22 : 0,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
                if (caption case final c?)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 2,
                    height: 13,
                    child: OverflowBox(
                      maxWidth: 160,
                      child: Text(
                        c,
                        key: const ValueKey('strip-version'),
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final tip = tooltip;
    return tip == null ? tab : Tooltip(message: tip, waitDuration: const Duration(milliseconds: 600), child: tab);
  }
}

/// Who is in the server, from the avatars: status, host / relay pills,
/// per member force ready, nudge and sit out, and the address to invite
/// friends.
Future<void> showMembersCard(BuildContext context) => showPopover<void>(
  context,
  at: const Alignment(0.7, -0.84),
  child: const MembersCard(),
);

/// "ip:port" for each of [addresses] friends could dial: IPv4, neither
/// loopback nor link-local, private (LAN) ranges first, no repeats.
List<String> inviteAddresses(Iterable<InternetAddress> addresses, String port) {
  bool private(List<int> b) =>
      b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] < 32);
  final usable = [
    for (final a in addresses)
      if (a.type == InternetAddressType.IPv4 &&
          !a.isLoopback &&
          !a.isLinkLocal &&
          !(a.rawAddress[0] == 169 && a.rawAddress[1] == 254))
        a,
  ];
  final ordered = [
    ...usable.where((a) => private(a.rawAddress)),
    ...usable.where((a) => !private(a.rawAddress)),
  ];
  return {for (final a in ordered) '${a.address}:$port'}.toList();
}

/// This machine's [inviteAddresses] (empty when the interfaces can't be
/// listed).
Future<List<String>> lanInviteAddresses(String port) async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return inviteAddresses([for (final i in interfaces) ...i.addresses], port);
  } catch (e) {
    debugPrint('list network interfaces failed: $e');
    return const [];
  }
}

class MembersCard extends StatelessWidget {
  /// This machine's invite addresses for a port (tests pass fixed ones).
  final Future<List<String>> Function(String port) lanAddresses;
  const MembersCard({super.key, this.lanAddresses = lanInviteAddresses});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('members-card'),
      elevation: 12,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 340,
        child: PartyWatch(
          builder: (context) {
            final session = SessionState.instance;
            final coord = session.coordinator;
            final r = coord.serverState.value;
            final hosting = coord.hostFile != null;
            final address = hosting
                ? null
                : '${session.lastForm.host}:${session.lastForm.port}';
            final delivery = r == null
                ? null
                : deliveryOf(r, selfId: coord.connection.memberId, names: coord.memberNames);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    ['In the server', ?address].join(' · '),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (delivery != null) SourceLine(delivery: delivery),
                for (final m in r?.members ?? const <MemberView>[])
                  _MemberTile(
                    member: m,
                    info: memberAvatarInfo(m, r, coord),
                    delivery: delivery == null ? null : memberDeliveryOf(m, r!, delivery),
                  ),
                if (r == null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'connecting…',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                const Divider(),
                if (address != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('copy-invite'),
                        onPressed: () => copyToClipboard(address, done: 'Invite address copied'),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy invite address'),
                      ),
                    ),
                  )
                else
                  _HostInvite(
                    port: session.lastForm.hostPort,
                    lanAddresses: lanAddresses,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final MemberView member;
  final AvatarInfo info;
  /// How it gets the media and its buffer; null with nothing up or alone.
  final MemberDelivery? delivery;
  const _MemberTile({
    required this.member,
    required this.info,
    this.delivery,
  });

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    final m = member;
    final since = m.goneSince;
    final status = m.presence == Presence.gone
        ? 'reconnecting…${since == null ? '' : ' (${sinceText(since, DateTime.now().toUtc())})'}'
        : m.presence == Presence.away
        ? 'sitting out'
        : m.presence == Presence.joining
        ? 'joining…'
        : m.error.isNotEmpty
        ? "can't play this: ${m.error}"
        : info.buffering
        ? 'buffering ${m.buffered.toStringAsFixed(1)} s'
        : m.ready
        ? 'ready'
        : 'not ready';
    return ListTile(
      key: ValueKey('member-${m.id}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: StatusAvatar(info: info, size: 36, badges: false),
      title: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(info.self ? '${m.name} (you)' : m.name),
          if (info.host) const Pill('host', Colors.amber),
          if (info.relaying)
            const Pill('passing the video on', Colors.lightBlueAccent),
        ],
      ),
      subtitle: DeliveryStatus(status: status, delivery: delivery),
      trailing: AppMenuButton<String>(
        tooltip: 'More',
        onSelected: (v) {
          switch (v) {
            case 'force':
              coord.forceTarget(m.id, !m.ready);
            case 'nudge':
              coord.nudgeMember(m.id);
            case 'out':
              coord.sitOut(m.id);
            case 'back':
              coord.joinBack();
          }
        },
        items: () => [
          if (m.presence != Presence.away) AppMenuItem(value: 'force', label: m.ready ? 'Force unready' : 'Force ready'),
          if (!info.self) const AppMenuItem(value: 'nudge', label: 'Nudge'),
          if (info.self && m.presence == Presence.away)
            const AppMenuItem(value: 'back', label: 'Join back')
          else if (m.presence != Presence.away)
            const AppMenuItem(value: 'out', label: 'Sit out'),
        ],
      ),
    );
  }
}

/// Hosting: the addresses friends on this network can join, the first
/// one behind "Copy invite address", and what friends elsewhere need.
class _HostInvite extends StatefulWidget {
  final String port;
  final Future<List<String>> Function(String port) lanAddresses;
  const _HostInvite({required this.port, required this.lanAddresses});

  @override
  State<_HostInvite> createState() => _HostInviteState();
}

class _HostInviteState extends State<_HostInvite> {
  late final Future<List<String>> _addresses = widget.lanAddresses(widget.port);

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return FutureBuilder<List<String>>(
      future: _addresses,
      builder: (context, snap) {
        final list = snap.data ?? const <String>[];
        void copy(String a) => copyToClipboard(a, done: 'Invite address copied');
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            key: const ValueKey('host-invite'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                key: const ValueKey('copy-invite'),
                onPressed: list.isEmpty ? null : () => copy(list.first),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy invite address'),
              ),
              if (snap.connectionState != ConnectionState.done)
                const SizedBox.shrink()
              else if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('No network address found', style: TextStyle(color: muted)),
                )
              else
                for (final a in list)
                  InkWell(
                    key: ValueKey('invite-$a'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => copy(a),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(a, style: const TextStyle(fontFamily: 'monospace'))),
                          Icon(Icons.copy, size: 14, color: muted),
                        ],
                      ),
                    ),
                  ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Text(
                  'Works for friends on your network. Friends elsewhere need port '
                  '${widget.port} forwarded on your router, or a server they can '
                  'all reach (like a VPS).',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
