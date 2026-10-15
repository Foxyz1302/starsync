import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../session/identity.dart';
import '../session/delivery.dart';
import '../session/party.dart';
import '../session/session_coordinator.dart';
import '../app/app_graph.dart';
import 'motion.dart';

/// What an avatar shows: who, their picture or initial on [color], and
/// the status the ring and badges carry.
class AvatarInfo {
  final String id;
  final String name;
  final Color color;
  final ImageProvider? image;
  final bool ready, buffering, relaying, host, self;
  /// Where they stand: joining (a little faded), away (dimmed with a moon),
  /// gone (dimmed, grey ring: reconnecting).
  final Presence presence;
  /// Since when they are gone; null otherwise.
  final DateTime? goneSince;
  /// Why their player cannot open the media (`members[].error`): an error
  /// mark; empty when it can.
  final String error;
  /// How it gets the media and its buffer ([MemberDelivery.detail]), for
  /// the hover; empty when unknown.
  final String delivery;
  /// Their Starsync version (`members[].app`), for the hover; '' unknown.
  final String app;
  const AvatarInfo({
    this.id = '',
    required this.name,
    required this.color,
    this.image,
    this.ready = false,
    this.buffering = false,
    this.relaying = false,
    this.presence = Presence.watching,
    this.goneSince,
    this.host = false,
    this.self = false,
    this.error = '',
    this.delivery = '',
    this.app = '',
  });

  /// Sitting out.
  bool get away => presence == Presence.away;

  /// Disconnected, in their grace period.
  bool get gone => presence == Presence.gone;
}

/// Stable colour for someone else (colours are not on the wire).
Color colorForName(String name) {
  const palette = [
    Colors.teal,
    Colors.orange,
    Colors.pink,
    Colors.blue,
    Colors.green,
    Colors.indigo,
    Colors.amber,
    Colors.cyan,
    Colors.red,
    Colors.deepPurple,
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

final _images = <Object, MemoryImage>{};

MemoryImage _memo(Object key, Uint8List bytes) {
  final hit = _images[key];
  if (hit != null && identical(hit.bytes, bytes)) return hit;
  if (_images.length > 64) _images.clear();
  return _images[key] = MemoryImage(bytes);
}

/// The one lookup for a member's picture: your own from the profile (no
/// round trip), anyone else's from the session's avatar cache by hash.
/// Callers rebuild on [SessionCoordinator.avatars] and [Profile.picture]
/// (see [PartyWatch]).
ImageProvider? memberAvatarImage(MemberView m, SessionCoordinator coord) {
  if (m.id.isNotEmpty && m.id == coord.connection.memberId) {
    final own = Profile.instance.picture.value;
    if (own != null) return _memo('self', own);
  }
  final bytes = coord.avatars.bytesFor(m.avatarHash);
  return bytes == null ? null : _memo(m.avatarHash, bytes);
}

/// Your own avatar from the profile (also offline).
AvatarInfo selfAvatarInfo(
    {bool ready = false, bool host = false, Presence presence = Presence.watching, String error = ''}) {
  final p = Profile.instance;
  final png = p.picture.value;
  final name = p.name.value;
  return AvatarInfo(
    name: name.isEmpty ? '?' : name,
    color: p.color.value,
    image: png == null ? null : _memo('self', png),
    ready: ready,
    host: host,
    self: true,
    presence: presence,
    error: error,
  );
}

/// [m] as the party strip, toasts and the chat show it.
AvatarInfo memberAvatarInfo(MemberView m, StateBroadcast? r, SessionCoordinator coord) {
  final self = m.id.isNotEmpty && m.id == coord.connection.memberId;
  final relay = r == null ? null : stateMediaRelay(r);
  final playing = r?.media != null;
  final delivery = r == null ? null : deliveryOf(r, selfId: coord.connection.memberId, names: coord.memberNames);
  return AvatarInfo(
    id: m.id,
    name: m.name,
    color: self ? Profile.instance.color.value : colorForName(m.name),
    image: memberAvatarImage(m, coord),
    ready: m.ready,
    buffering: countsForReady(m) && m.ready && playing && m.buffered < r!.bufferNeed,
    relaying: relay != null && relay.source.isNotEmpty && relay.source == m.id,
    presence: m.presence,
    goneSince: m.goneSince,
    // The state marks the host (`members[].host`); your own app also
    // knows before the first state.
    host: m.host || (self && coord.hostFile != null),
    self: self,
    error: m.error,
    delivery: delivery == null ? '' : memberDeliveryOf(m, r!, delivery).detail,
    app: m.app,
  );
}

/// Everyone in the server, from the latest state.
List<AvatarInfo> partyAvatars(SessionCoordinator c) {
  final r = c.serverState.value;
  return [for (final m in r?.members ?? const <MemberView>[]) memberAvatarInfo(m, r, c)];
}

/// Rebuilds [builder] when the party state, your profile or a member's
/// picture changes.
class PartyWatch extends StatelessWidget {
  final WidgetBuilder builder;
  const PartyWatch({super.key, required this.builder});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppScope.of(context).coordinator.avatars,
        builder: (context, _) => SignalBuilder(builder: (context) => builder(context)),
      );
}

/// Circle avatar with a status ring outside it and a gap in the background
/// colour, so overlapping neighbours never hide the status. Crown = host,
/// tower = passing the video on, spinner = buffering, a little faded =
/// joining, dimmed with a grey ring = gone (reconnecting), dimmed with a
/// moon = sitting out, red "!" = cannot play the media.
class StatusAvatar extends StatelessWidget {
  final AvatarInfo info;
  final double size;

  /// Host crown and relay tower; off where the context already says it.
  final bool badges;

  /// Ring colour when not ready (the profile shows none at all).
  final bool ring;
  const StatusAvatar({super.key, required this.info, required this.size, this.badges = true, this.ring = true});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerLowest;
    final ringColor = !ring
        ? bg
        : info.gone
            ? Colors.grey.shade700
            : info.buffering
                ? Colors.amber
                : info.ready
                    ? Colors.greenAccent.shade400
                    : Colors.grey;
    final badge = size * 0.42;
    // Ring and gap scale with the avatar (2 px at strip size).
    final stroke = (size * 0.055).clamp(2.0, 4.0);
    final initial = info.name.isEmpty ? '?' : info.name.characters.first.toUpperCase();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Fills the box: a non-positioned Stack child only gets loose
          // constraints, and CircleAvatar then falls back to 40 px.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: ringColor),
              padding: EdgeInsets.all(stroke),
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                padding: EdgeInsets.all(stroke),
                child: Opacity(
                  opacity: info.gone || info.away
                      ? 0.4
                      : info.presence == Presence.joining
                          ? 0.7
                          : 1,
                  child: CircleAvatar(
                    radius: size / 2,
                    backgroundColor: info.color,
                    backgroundImage: info.image,
                    child: info.image != null
                        ? null
                        : Text(initial, style: TextStyle(fontSize: size * 0.38, color: Colors.white)),
                  ),
                ),
              ),
            ),
          ),
          if (info.buffering)
            Positioned.fill(child: CircularProgressIndicator(strokeWidth: stroke, color: ringColor)),
          if (badges && info.host)
            Positioned(
              left: -4,
              top: -6,
              child: Transform.rotate(
                angle: -0.4,
                child: Icon(
                  Icons.workspace_premium,
                  size: badge,
                  color: Colors.amber,
                  shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
                ),
              ),
            ),
          if (info.away)
            Positioned(
              key: const ValueKey('away-mark'),
              left: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: Icon(Icons.bedtime, size: (badge * 0.8).clamp(10.0, 24.0), color: Colors.blueGrey.shade200),
              ),
            ),
          if (info.error.isNotEmpty)
            Positioned(
              key: const ValueKey('error-mark'),
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: Icon(Icons.error, size: (badge * 0.8).clamp(10.0, 24.0), color: Colors.redAccent.shade200),
              ),
            ),
          if (badges && info.relaying)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: Icon(Icons.cell_tower, size: badge * 0.8, color: Colors.lightBlueAccent),
              ),
            ),
        ],
      ),
    );
  }
}

/// Overlapping avatars, host first then ready (the stack itself reads as
/// progress); they spread apart on hover. "+N" past [shown].
class AvatarStack extends StatefulWidget {
  final List<AvatarInfo> members;
  final VoidCallback? onTap;
  final int shown;
  final double size;
  const AvatarStack({super.key, required this.members, this.onTap, this.shown = 5, this.size = 42});

  @override
  State<AvatarStack> createState() => _AvatarStackState();
}

class _AvatarStackState extends State<AvatarStack> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    int rank(AvatarInfo m) => m.host ? 0 : (m.gone ? 4 : m.away ? 3 : m.ready ? 1 : 2);
    final sorted = [...widget.members]..sort((a, b) => rank(a) - rank(b));
    final visible = sorted.take(widget.shown).toList();
    final extra = sorted.length - visible.length;
    final step = _hover ? size + 6 : size * 0.62;
    final count = visible.length + (extra > 0 ? 1 : 0);
    final width = count == 0 ? 0.0 : step * (count - 1) + size;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          key: const ValueKey('avatar-stack'),
          duration: easeTime,
          curve: ease,
          width: width,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = visible.length - 1; i >= 0; i--)
                AnimatedPositioned(
                  key: ValueKey('stack-${visible[i].id}-${visible[i].name}'),
                  duration: easeTime,
                  curve: ease,
                  left: i * step,
                  top: 0,
                  child: Tooltip(
                    message: [
                      visible[i].error.isEmpty
                          ? visible[i].name
                          : "${visible[i].name} can't play this: ${visible[i].error}",
                      if (visible[i].delivery.isNotEmpty) visible[i].delivery,
                      if (visible[i].app.isNotEmpty) 'Starsync ${visible[i].app}',
                    ].join('\n'),
                    child: StatusAvatar(info: visible[i], size: size),
                  ),
                ),
              if (extra > 0)
                AnimatedPositioned(
                  duration: easeTime,
                  curve: ease,
                  left: visible.length * step,
                  top: 0,
                  child: CircleAvatar(
                    radius: size / 2,
                    child: Text('+$extra', style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small coloured label ("host", "passing the video on").
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
      );
}

/// Someone in a feed line or toast: by member [id] when it has one, else
/// by display [name]; from the latest state when still there, else their
/// initial on a stable colour.
AvatarInfo avatarForName(String name, SessionCoordinator c, [String id = '']) {
  final r = c.serverState.value;
  final members = r?.members ?? const <MemberView>[];
  // By id when the line has one (names change and repeat), else by name.
  for (final m in members) {
    if (id.isNotEmpty ? m.id == id : m.name == name) return memberAvatarInfo(m, r, c);
  }
  return AvatarInfo(name: name, color: colorForName(name));
}
