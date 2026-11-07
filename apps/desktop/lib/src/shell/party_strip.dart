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

/// Every avatar in the strip, yours and the party's (the picture fills
/// it, no ring).
const stripAvatarSize = 48.0;

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
                borderRadius: AvatarShape.of(context).radius(stripAvatarSize),
                onTap: onProfile,
                child: StatusAvatar(
                  info: self == null
                      ? selfAvatarInfo(host: social && home, error: online ? coord.playerError.value : '')
                      : memberAvatarInfo(self, coord.serverState.value, coord),
                  size: stripAvatarSize,
                  marks: social,
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

/// Who is in the server: the server (its name, who stands where, its
/// address and version), where the media comes from, everyone (standing,
/// route, buffer, actions) and the invite (yours) or its link (a
/// friend's).
Future<void> showMembersCard(BuildContext context) => showPopover<void>(
  context,
  at: const Alignment(0.7, -0.84),
  child: const MembersCard(),
);

/// The members card's side inset: the header, the rows and the invite
/// line up on it.
const _cardInset = 16.0;

class MembersCard extends StatelessWidget {
  const MembersCard({super.key});

  /// The rows' order, as the strip's avatars: host, watching, BRB, out,
  /// gone; you first among equals.
  static int _rank(AvatarInfo m) =>
      (m.host ? 0 : (m.gone ? 8 : m.isOut ? 6 : m.brb ? 4 : 2)) + (m.self ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('members-card'),
      elevation: 12,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        child: PartyWatch(
          builder: (context) {
            final graph = AppScope.of(context);
            final coord = graph.coordinator;
            final nav = graph.navigation;
            final r = coord.serverState.value;
            final home = nav.home.value;
            final address = home ? null : nav.address.value;
            final status = coord.status.value;
            final delivery = status.delivery;
            final server = nav.serverVersion.value;
            final rows = [
              for (final m in r?.members ?? const <MemberView>[]) (m, memberAvatarInfo(m, r, coord)),
            ]..sort((a, b) => _rank(a.$2) - _rank(b.$2));
            final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.3);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The server: its name, who stands where, then where it is.
                Padding(
                  padding: const EdgeInsets.fromLTRB(_cardInset + 4, 16, _cardInset + 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        serverName(graph),
                        key: const ValueKey('members-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2),
                      ),
                      if (status.party.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(status.party, style: muted.copyWith(fontSize: 13, color: scheme.onSurface.withValues(alpha: 0.8))),
                      ],
                      if ((address != null && address.isNotEmpty) || server.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (address != null && address.isNotEmpty)
                              Flexible(
                                child: Text(address, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                              ),
                            if (address != null && address.isNotEmpty && server.isNotEmpty)
                              Text(' · ', style: muted),
                            if (server.isNotEmpty)
                              VersionText(key: const ValueKey('server-version'), label: 'Server', version: server),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (delivery != null) SourceLine(delivery: delivery),
                const SizedBox(height: 4),
                for (final (m, info) in rows)
                  _MemberTile(
                    member: m,
                    info: info,
                    delivery: delivery == null ? null : memberDeliveryOf(m, r!, delivery),
                  ),
                if (r == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_cardInset + 4, 8, _cardInset + 4, 16),
                    child: Text('connecting…', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                const SizedBox(height: 4),
                Divider(height: 1, indent: _cardInset, endIndent: _cardInset, color: scheme.outlineVariant.withValues(alpha: 0.5)),
                if (home)
                  const YourInvite()
                else if (address != null && address.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_cardInset - 4, 6, _cardInset, 8),
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

/// One person: their picture (the strip's: standing badge, crown,
/// tower), name with "you", host and their version, then their standing
/// in its badge's colour with how the media reaches them and a buffer dot;
/// the ⋮ has their card's actions.
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

  static const _avatar = 40.0;

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    final scheme = Theme.of(context).colorScheme;
    final m = member;
    final since = m.goneSince;
    final (String standing, Color tone) = m.gone
        ? ('reconnecting…${since == null ? '' : ' (${sinceText(since, DateTime.now().toUtc())})'}', Colors.amber)
        : m.presence == Presence.brb
        ? ('BRB', StateBadge.glyphColor(Presence.brb))
        : m.presence == Presence.afk
        ? ('AFK', StateBadge.glyphColor(Presence.afk))
        : m.presence == Presence.out
        ? ('out', StateBadge.glyphColor(Presence.out))
        : m.error.isNotEmpty
        ? ("can't play this: ${m.error}", Colors.redAccent.shade100)
        : info.activity == AvatarActivity.loading
        ? (info.progress == null ? 'loading…' : 'loading · ${(info.progress! * 100).round()}%', scheme.onSurface)
        : ('watching', scheme.onSurfaceVariant);
    final d = delivery;
    final route = d == null || d.route == DeliveryRoute.source || m.gone || m.isOut ? '' : d.short;
    final health = d?.health;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.3);
    final person = PersonRef.of(info);
    return Padding(
      key: ValueKey('member-${m.id}'),
      padding: const EdgeInsets.fromLTRB(_cardInset, 5, _cardInset - 8, 5),
      child: Row(
        children: [
          // The person's card, without the link back to this card.
          PersonHover(
            person: person,
            everyone: false,
            child: StatusAvatar(info: info, size: _avatar),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: PersonHover(
                        person: person,
                        everyone: false,
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: m.name),
                            if (info.self)
                              TextSpan(text: '  you', style: muted.copyWith(fontWeight: FontWeight.w500)),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.25),
                        ),
                      ),
                    ),
                    if (info.host) ...[const SizedBox(width: 8), const Pill('host', Colors.amber)],
                    if (m.app.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      VersionText(key: ValueKey('version-${m.id}'), version: m.app),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Tooltip(
                  message: d?.detail ?? '',
                  waitDuration: const Duration(milliseconds: 400),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: standing,
                                style: TextStyle(
                                    color: tone,
                                    fontWeight: tone == scheme.onSurfaceVariant ? FontWeight.w400 : FontWeight.w500)),
                            if (route.isNotEmpty) TextSpan(text: ' · $route'),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                      if (health != null) ...[
                        const SizedBox(width: 8),
                        AnimatedContainer(
                          key: const ValueKey('health-dot'),
                          duration: easeTime,
                          curve: ease,
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: healthColor(health), shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The same actions as the person's card.
          AppMenuButton<MemberAction>(
            tooltip: 'More',
            onSelected: (a) => runMemberAction(coord, m.id, a),
            items: () => [
              for (final a in memberActions(info)) AppMenuItem(value: a.action, label: a.label, icon: a.icon),
            ],
          ),
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
