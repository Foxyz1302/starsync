import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';
import 'package:window_manager/window_manager.dart';

import '../screens/demo/shell_demo.dart';
import '../screens/home/update_indicator.dart';
import '../screens/session/jellyfin_widgets.dart' show ViaHostBadge;
import '../state/session_state.dart';
import '../update/update_controller.dart';
import '../widgets/dialogs.dart';
import '../widgets/window_buttons.dart';
import 'avatar.dart';
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

/// Below this window width the strip shows 3 avatars and no server text,
/// so the tabs keep their room.
const stripCompactBelow = 1100.0;

/// The member plays the current Jellyfin item through the host's relay.
bool viaHostOf(MemberView m, JellyfinRef? ref) =>
    ref != null && m.jf[ref.serverId] == false;

/// The 60 px strip over everything: your avatar (profile), the tabs, and
/// the party: offline Join / Host, online the avatars (members card),
/// server and readiness, chat and Leave. Empty space drags the window.
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

  /// Online with something up but the player closed: brings it back.
  final VoidCallback? onShowPlayer;
  final UpdateController? updates;

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
    this.onShowPlayer,
    this.updates,
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
        final self = online ? coord.selfMember.value : null;
        return Row(
          children: [
            const SizedBox(width: 16),
            Tooltip(
              message: 'Your profile',
              child: InkWell(
                key: const ValueKey('strip-profile'),
                customBorder: const CircleBorder(),
                onTap: onProfile,
                child: StatusAvatar(
                  info: selfAvatarInfo(
                    ready: self?.ready ?? false,
                    host: online && coord.hostFile != null,
                  ),
                  size: 32,
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
                            onTap: () => onTab(t),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (kDebugMode)
              IconButton(
                tooltip: 'Layout demo (debug builds only)',
                icon: const Icon(
                  Icons.bug_report_outlined,
                  size: 20,
                  color: Colors.amber,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ShellDemo()),
                ),
              ),
            UpdateIndicator(controller: updates),
            const SizedBox(width: 8),
            if (online) ...[
              if (onShowPlayer != null)
                IconButton(
                  key: const ValueKey('show-player'),
                  tooltip: 'Show the player',
                  onPressed: onShowPlayer,
                  icon: const Icon(Icons.smart_display_outlined, size: 20),
                ),
              PartyWatch(
                builder: (context) => AvatarStack(
                  key: const ValueKey('party-avatars'),
                  members: partyAvatars(coord),
                  shown: compact ? 3 : 5,
                  onTap: () => showMembersCard(context),
                ),
              ),
              const SizedBox(width: 10),
              if (!compact) _ServerLabel(scheme: scheme),
              const SizedBox(width: 6),
              Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: IconButton(
                  key: const ValueKey('strip-chat'),
                  tooltip: 'Chat & activity',
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
              const SizedBox(width: 4),
              OutlinedButton(
                key: const ValueKey('strip-leave'),
                onPressed: onLeave,
                child: const Text('Leave'),
              ),
            ] else ...[
              if (!compact)
                Text(
                  'Offline',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                key: const ValueKey('strip-join'),
                onPressed: onJoin,
                child: const Text('Join'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('strip-host'),
                onPressed: onHost,
                child: const Text('Host'),
              ),
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
                child: DragToMoveArea(child: SizedBox.expand()),
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
      final members = r?.members ?? const <MemberView>[];
      final ready = members.where((m) => m.ready).length;
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
            r == null ? 'connecting…' : 'ready $ready/${members.length}',
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

/// "Your server" when hosting, else the address joined.
String serverName() {
  final session = SessionState.instance;
  if (session.coordinator.hostFile != null) return 'Your server';
  return session.lastForm.host;
}

/// One strip tab: label and an underline that grows in when selected.
class StripTab extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  const StripTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
          child: SizedBox(
            height: partyStripHeight,
            child: Column(
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
          ),
        ),
      ),
    );
  }
}

/// Who is in the server, from the avatars: status, host / relay pills,
/// and per member force ready and kick.
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
            final session = SessionState.instance;
            final coord = session.coordinator;
            final r = coord.serverState.value;
            final hosting = coord.hostFile != null;
            final address = hosting
                ? null
                : '${session.lastForm.host}:${session.lastForm.port}';
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
                for (final m in r?.members ?? const <MemberView>[])
                  _MemberTile(
                    member: m,
                    info: memberAvatarInfo(m, r, coord),
                    viaHost: viaHostOf(m, coord.currentRef.value),
                  ),
                if (r == null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'connecting…',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (address != null) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: address)),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy address'),
                      ),
                    ),
                  ),
                ] else
                  const SizedBox(height: 8),
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
  final bool viaHost;
  const _MemberTile({
    required this.member,
    required this.info,
    required this.viaHost,
  });

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    final m = member;
    final status = m.stale
        ? 'reconnecting…'
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
          if (viaHost) const ViaHostBadge(),
        ],
      ),
      subtitle: Text(status),
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) async {
          if (v == 'force') {
            coord.forceTarget(m.id, !m.ready);
          } else if (v == 'kick') {
            final ok = await showKickConfirmDialog(context, m.name);
            if (ok == true) coord.kick(m.id);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'force',
            child: Text(m.ready ? 'Force unready' : 'Force ready'),
          ),
          if (!info.self)
            PopupMenuItem(
              value: 'kick',
              child: Text(
                'Kick',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
