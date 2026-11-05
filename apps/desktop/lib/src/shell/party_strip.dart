import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName, displayVersion, shortVersion;
import '../session/delivery.dart';
import '../session/party.dart';
import '../app/app_graph.dart';
import '../session/invite.dart';
import '../session/navigation.dart' show Place;
import '../widgets/app_keys.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import '../widgets/window_buttons.dart';
import 'avatar.dart';
import 'delivery_line.dart';
import 'motion.dart';
import 'person_card.dart';
import 'your_invite.dart';

export 'your_invite.dart' show YourInvite, inviteFriends;

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
/// the party. Alone on your own server it is a plain player's: Join a
/// friend and Invite (a "Sharing" chip while your server is open to
/// friends); with others there the avatars (each person's card), server
/// and readiness (members card), chat, and Invite (yours) or Leave (a
/// friend's). Empty space drags the window. The arrow keys never move
/// focus onto it.
class PartyStrip extends StatelessWidget {
  final ShellTab tab;
  final ValueChanged<ShellTab> onTab;
  final bool chatOpen;
  final int unread;
  final VoidCallback onChat;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onProfile;
  /// Opens your server to friends (if it is not yet) and copies the
  /// invite.
  final VoidCallback onInvite;

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
    required this.onLeave,
    required this.onProfile,
    required this.onInvite,
    this.onShowPlayer,
    this.windowControls = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < stripCompactBelow;
    final row = SignalBuilder(
      builder: (context) {
        final graph = AppScope.of(context);
        final coord = graph.coordinator;
        final nav = graph.navigation;
        final online = nav.online.value;
        final home = nav.home.value;
        final friend = nav.place.value == Place.friend;
        // Others there (or a friend's server): the party; else a plain
        // player (D9).
        final social = friend || (online && !coord.alone.value);
        final shared = graph.yourServer.shared.value;
        final canInvite = graph.yourServer.port.value != null && !graph.yourServer.busy.value;
        final self = social ? coord.selfMember.value : null;
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
                    host: social && home,
                    error: online ? coord.playerError.value : '',
                  ),
                  size: stripAvatarSize,
                  ring: social,
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
                            // The version a rest of the mouse away (also at
                            // the bottom of Settings and in About).
                            tooltip: t == ShellTab.settings ? '$appName ${displayVersion()}' : null,
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
            if (social) ...[
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
              if (friend)
                OutlinedButton(
                  key: const ValueKey('strip-leave'),
                  onPressed: onLeave,
                  child: const Text('Leave'),
                )
              else
                _InviteButton(compact: compact, onInvite: canInvite ? onInvite : null),
            ] else ...[
              if (shared != null) ...[
                _SharingChip(compact: compact, port: shared.port),
                const SizedBox(width: 8),
              ],
              if (compact)
                FilledButton.tonal(key: const ValueKey('strip-join'), onPressed: onJoin, child: const Text('Join'))
              else
                FilledButton.tonalIcon(
                  key: const ValueKey('strip-join'),
                  onPressed: onJoin,
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('Join a friend'),
                ),
              const SizedBox(width: 8),
              _InviteButton(compact: compact, onInvite: canInvite ? onInvite : null),
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
            // The arrow keys never move focus onto the strip (from the
            // library, or the player's keys): Enter would press it.
            Positioned.fill(child: FocusTraversalGroup(descendantsAreTraversable: false, child: row)),
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
      // "connecting…", "reconnecting…", "ready 2/3" (the ready counter
      // counts who the presence policy counts), from the one status.
      final graph = AppScope.of(context);
      final line = graph.coordinator.status.value.party;
      // A click: who is in it (the avatars' clicks are each person's).
      // The ▾, the hover and the tooltip say it opens something.
      return Tooltip(
        message: 'Everyone in the server',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
        key: const ValueKey('server-label'),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.white.withValues(alpha: 0.06),
        onTap: () => showMembersCard(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(
                    serverName(graph),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, height: 1.1),
                  ),
                ),
                Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
              ]),
              Text(
                line,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        ),
      );
    },
  );
}

/// "Your server" at home, else the joined server's name (its `--name`),
/// or its address while unknown.
String serverName(AppGraph graph) {
  final nav = graph.navigation;
  if (nav.home.value) return 'Your server';
  final label = nav.serverLabel.value;
  return label.isNotEmpty ? label : nav.address.value;
}

/// Invite: opens your server to friends (if it is not yet) and copies
/// the invite.
class _InviteButton extends StatelessWidget {
  final bool compact;
  final VoidCallback? onInvite;
  const _InviteButton({required this.compact, required this.onInvite});

  @override
  Widget build(BuildContext context) {
    const tip = 'Copy an invite friends can join with (opens your server to them)';
    if (compact) {
      return Tooltip(
        message: tip,
        child: FilledButton(key: const ValueKey('strip-invite'), onPressed: onInvite, child: const Text('Invite')),
      );
    }
    return Tooltip(
      message: tip,
      child: FilledButton.icon(
        key: const ValueKey('strip-invite'),
        onPressed: onInvite,
        icon: const Icon(Icons.group_add_outlined, size: 18),
        label: const Text('Invite'),
      ),
    );
  }
}

/// Your server is open to friends and nobody came yet: the port; a click
/// opens the members card (the invite, Stop sharing).
class _SharingChip extends StatelessWidget {
  final bool compact;
  final int port;
  const _SharingChip({required this.compact, required this.port});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Friends can join with your invite. Click for the invite or to stop sharing.',
      child: InkWell(
        key: const ValueKey('sharing-chip'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => showMembersCard(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.podcasts_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              const Text('Sharing', style: TextStyle(fontWeight: FontWeight.w600)),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text('port $port', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ],
            ],
          ),
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
  const StripTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.tooltip,
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
/// per member force ready, nudge and sit out, and the invite (yours) or
/// the address (a friend's).
Future<void> showMembersCard(BuildContext context) => showPopover<void>(
  context,
  at: const Alignment(0.7, -0.84),
  child: const MembersCard(),
);

class MembersCard extends StatelessWidget {
  const MembersCard({super.key});

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
            final graph = AppScope.of(context);
            final coord = graph.coordinator;
            final nav = graph.navigation;
            final r = coord.serverState.value;
            final home = nav.home.value;
            final address = home ? null : nav.address.value;
            final delivery = coord.status.value.delivery;
            final server = nav.serverVersion.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        home ? 'Your server' : ['In the server', ?address].join(' · '),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (server.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: VersionText(
                            key: const ValueKey('server-version'),
                            label: 'Server',
                            version: server,
                          ),
                        ),
                    ],
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
                if (home)
                  const YourInvite()
                else if (address != null && address.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('copy-invite'),
                        onPressed: () => copyToClipboard(
                            context,
                            friendInviteLink(address, nav.serverLabel.peek(),
                                secret: AppScope.of(context).connection.params?.secret ?? ''),
                            done: 'Invite link copied'),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy invite link'),
                      ),
                    ),
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
    final coord = AppScope.of(context).coordinator;
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
      // The person's card, without the link back to this card.
      leading: PersonHover(
        person: PersonRef.of(info),
        everyone: false,
        child: StatusAvatar(info: info, size: 36, badges: false),
      ),
      title: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PersonHover(
            person: PersonRef.of(info),
            everyone: false,
            child: Text(info.self ? '${m.name} (you)' : m.name),
          ),
          if (m.app.isNotEmpty) VersionText(key: ValueKey('version-${m.id}'), version: m.app),
          if (info.host) const Pill('host', Colors.amber),
          if (info.relaying)
            const Pill('passing the video on', Colors.lightBlueAccent),
        ],
      ),
      subtitle: DeliveryStatus(status: status, delivery: delivery),
      // The same actions as the person's card.
      trailing: AppMenuButton<MemberAction>(
        tooltip: 'More',
        onSelected: (a) => runMemberAction(coord, m.id, a),
        items: () => [
          for (final a in memberActions(info)) AppMenuItem(value: a.action, label: a.label, icon: a.icon),
        ],
      ),
    );
  }
}

/// A Starsync version, quiet ("1.3.0"), amber with a hint when it is not
/// the one this app runs; [label] before it ("Server 1.3.0").
class VersionText extends StatelessWidget {
  final String version;
  final String? label;
  const VersionText({super.key, required this.version, this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final differs = versionDiffers(version);
    final text = Text(
      [?label, version].join(' '),
      style: TextStyle(
        fontSize: 11,
        color: differs ? Colors.amber.shade300 : scheme.onSurfaceVariant.withValues(alpha: 0.8),
        fontWeight: differs ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    if (!differs) return text;
    return Tooltip(message: 'You run ${shortVersion()}', child: text);
  }
}

/// [version] is not the one this app runs (a dev run matches anything:
/// it has no version of its own).
bool versionDiffers(String version, {String own = appVersion}) =>
    version.isNotEmpty && own != '0.0.0-dev' && version != '0.0.0-dev' && version != own;

/// The invite link to a friend's server you are in ([address] as dialled,
/// "host:port"), with the password you joined with: the link is the key,
/// as for your own server.
String friendInviteLink(String address, String name, {String secret = ''}) {
  final a = addressIn(address);
  final port = a == null ? null : int.tryParse(a.port);
  if (a == null || port == null) return address;
  return InviteLink(host: a.host, port: port, name: name, secret: secret).uri;
}
