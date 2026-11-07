import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../session/identity.dart';
import '../session/delivery.dart';
import '../session/session_coordinator.dart';
import '../app/app_graph.dart';
import 'motion.dart';
import 'person_card.dart' show PersonHover, PersonRef;

/// Something happening to someone's player, drawn over the picture's edge
/// only while it lasts.
enum AvatarActivity {
  none,

  /// Its video is loading (joining, catching up, or the group waits for
  /// its buffer): a white run round the edge, as long as its buffer is
  /// along ([AvatarInfo.progress]), else a short arc going round.
  loading,

  /// Disconnected, in its grace: an amber stretch going round.
  reconnecting,
}

/// What an avatar shows: who, their picture or initial on [color], their
/// standing (a badge) and what happens to their player (the edge).
class AvatarInfo {
  final String id;
  final String name;
  final Color color;
  final ImageProvider? image;
  final bool relaying, host, self;
  /// Where they stand: BRB (a cup), AFK ("Zz", darkened), Out (an eye
  /// with a line, darkened).
  final Presence presence;
  /// Loading or reconnecting: drawn on the edge while it lasts.
  final AvatarActivity activity;
  /// Loading: how far its buffer is towards what the group needs (0..1);
  /// null when not known.
  final double? progress;
  /// Since when they are gone; null otherwise.
  final DateTime? goneSince;
  /// Since when they stand where they do (BRB, AFK, Out); null for in.
  final DateTime? since;
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
    this.relaying = false,
    this.presence = Presence.watching,
    this.activity = AvatarActivity.none,
    this.progress,
    this.goneSince,
    this.since,
    this.host = false,
    this.self = false,
    this.error = '',
    this.delivery = '',
    this.app = '',
  });

  /// The same with [image] as the picture.
  AvatarInfo withImage(ImageProvider image) => AvatarInfo(
        id: id,
        name: name,
        color: color,
        image: image,
        relaying: relaying,
        presence: presence,
        activity: activity,
        progress: progress,
        goneSince: goneSince,
        since: since,
        host: host,
        self: self,
        error: error,
        delivery: delivery,
        app: app,
      );

  /// AFK or Out.
  bool get isOut => presence.isOut;

  /// BRB.
  bool get brb => presence == Presence.brb;

  /// Disconnected, in their grace period.
  bool get gone => activity == AvatarActivity.reconnecting;
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
AvatarInfo selfAvatarInfo({bool host = false, Presence presence = Presence.watching, String error = ''}) {
  final p = Profile.instance;
  final png = p.picture.value;
  final name = p.name.value;
  return AvatarInfo(
    name: name.isEmpty ? '?' : name,
    color: p.color.value,
    image: png == null ? null : _memo('self', png),
    host: host,
    self: true,
    presence: presence,
    error: error,
  );
}

/// [m]'s player activity in [r]: reconnecting while gone; loading while it
/// joins or catches up, or while the group waits for its video.
AvatarActivity activityOf(MemberView m, StateBroadcast? r) {
  if (m.gone) return AvatarActivity.reconnecting;
  if (r == null || r.media == null || m.isOut) return AvatarActivity.none;
  if (m.loading || (r.hold?.video.contains(m.id) ?? false)) return AvatarActivity.loading;
  return AvatarActivity.none;
}

/// While [m] loads: its buffer against what the group needs now (0..1);
/// null when that is not known (nothing needed, not loading).
double? loadProgressOf(MemberView m, StateBroadcast? r) {
  if (r == null || activityOf(m, r) != AvatarActivity.loading) return null;
  final need = r.bufferNeed;
  if (need <= 0) return null;
  return (m.buffered / need).clamp(0.0, 1.0);
}

/// [m] as the party strip, toasts and the chat show it.
AvatarInfo memberAvatarInfo(MemberView m, StateBroadcast? r, SessionCoordinator coord) {
  final self = m.id.isNotEmpty && m.id == coord.connection.memberId;
  final relay = r == null ? null : stateMediaRelay(r);
  final delivery = r == null ? null : deliveryOf(r, selfId: coord.connection.memberId, names: coord.memberNames);
  return AvatarInfo(
    id: m.id,
    name: m.name,
    color: self ? Profile.instance.color.value : colorForName(m.name),
    image: memberAvatarImage(m, coord),
    relaying: relay != null && relay.source.isNotEmpty && relay.source == m.id,
    presence: m.presence,
    activity: activityOf(m, r),
    progress: loadProgressOf(m, r),
    goneSince: m.goneSince,
    since: m.since,
    // The state marks the host (`members[].host`); your own app also
    // knows before the first state.
    host: m.host || (self && coord.hostFile != null),
    self: self,
    error: m.error,
    delivery: delivery == null ? '' : memberDeliveryOf(m, r!, delivery).detail,
    app: m.app,
  );
}

/// The shape people's pictures have: a rounded square (corner 22 % of
/// the size) or a circle (Settings → Party → More, "Avatar shape").
class AvatarShape {
  final bool circle;
  const AvatarShape({this.circle = false});

  /// Corner as a share of the size.
  double get corner => circle ? 0.5 : 0.22;

  /// The shape at [size] px.
  RRect at(double size) => RRect.fromRectAndRadius(Offset.zero & Size.square(size), Radius.circular(size * corner));

  BorderRadius radius(double size) => BorderRadius.circular(size * corner);

  /// The setting's shape (tracked when read in a builder); a rounded
  /// square outside the app (tests without a graph).
  static AvatarShape of(BuildContext context) {
    final graph = AppScope.maybeOf(context);
    return AvatarShape(circle: graph?.coordinator.settings.avatarCircle.value ?? false);
  }
}

/// A person: the picture fills the whole shape (no ring). BRB, AFK and
/// Out are a badge in a small dark tile on the bottom-right; AFK and Out
/// are darkened. Loading and reconnecting run along the shape's edge,
/// over the picture, only while they last. Crown = host, tower = passing
/// the video on, red "!" = cannot play the media. [badges]: the crown and
/// tower (off where the context already says it); [marks]: the standing
/// and activity (off for tiny pictures in a line); [edge]: an outline in
/// the background colour (the shape overlaps a neighbour).
class StatusAvatar extends StatelessWidget {
  final AvatarInfo info;
  final double size;
  final bool badges;
  final bool marks;
  final bool edge;

  /// A little darkened (someone else stands out).
  final bool dim;
  const StatusAvatar({
    super.key,
    required this.info,
    required this.size,
    this.badges = true,
    this.marks = true,
    this.edge = false,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) => SignalBuilder(builder: (context) => _build(context, AvatarShape.of(context)));

  Widget _build(BuildContext context, AvatarShape shape) {
    final bg = Theme.of(context).colorScheme.surfaceContainerLowest;
    final initial = info.name.isEmpty ? '?' : info.name.characters.first.toUpperCase();
    final mark = (size * 0.42).clamp(10.0, 24.0);
    final darken = marks && info.isOut ? 0.62 : (dim ? 0.38 : 0.0);
    // Dimmed by darkening, not transparency: an overlapping neighbour must
    // not show through. The picture is one draw clipped to the shape, its
    // darkening a filter on it: anything drawn under it to the same edge
    // (the person's colour, a black layer) bleeds through the edge's
    // anti-aliased pixels as a thin frame. The colour stays only for a
    // picture with transparent parts, a pixel inside the edge.
    final image = info.image;
    final picture = TweenAnimationBuilder<double>(
      tween: Tween(end: darken),
      duration: easeTime,
      curve: ease,
      builder: (context, d, _) {
        final shade = Colors.black.withValues(alpha: d);
        final color = Color.alphaBlend(shade, info.color);
        if (image == null) {
          return DecoratedBox(
            decoration: BoxDecoration(color: color, borderRadius: shape.radius(size)),
            child: Center(
              child: Text(initial,
                  style: TextStyle(fontSize: size * 0.42, color: Color.alphaBlend(shade, Colors.white))),
            ),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(1),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, borderRadius: shape.radius(size - 2)),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape.radius(size),
                image: DecorationImage(
                  image: image,
                  fit: BoxFit.cover,
                  colorFilter: d > 0 ? ColorFilter.mode(shade, BlendMode.srcATop) : null,
                ),
              ),
            ),
          ],
        );
      },
    );
    final activity = marks ? info.activity : AvatarActivity.none;
    final tile = badgeSize(size);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Overlapping shapes are parted by a background-coloured halo
          // behind the picture, not an outline over its edge: two
          // anti-aliased edges on top of each other let the picture show
          // through at the corners (jagged at rest, smooth once spread).
          if (edge)
            Positioned(
              left: -2,
              top: -2,
              right: -2,
              bottom: -2,
              child: DecoratedBox(
                  decoration: BoxDecoration(color: bg, borderRadius: shape.radius(size + 4))),
            ),
          Positioned.fill(child: picture),
          if (edge || activity != AvatarActivity.none)
            Positioned.fill(
              child: AvatarEdge(
                  shape: shape.at(size), edge: edge ? bg : null, activity: activity, progress: info.progress),
            ),
          if (badges && info.host)
            Positioned(
              left: -4,
              top: -6,
              child: Transform.rotate(
                angle: -0.4,
                child: Icon(
                  Icons.workspace_premium,
                  size: mark,
                  color: Colors.amber,
                  shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
                ),
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
                child: Icon(Icons.error, size: mark * 0.8, color: Colors.redAccent.shade200),
              ),
            ),
          if (badges && info.relaying)
            Positioned(
              left: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: Icon(Icons.cell_tower, size: mark * 0.8, color: Colors.lightBlueAccent),
              ),
            ),
          // The standing's tile sits a third over the bottom-right corner.
          if (marks && info.presence != Presence.watching)
            Positioned(
              key: ValueKey('state-${info.presence.wire}'),
              right: -tile / 3,
              bottom: -tile / 3,
              child: StateBadge(presence: info.presence, size: tile),
            ),
        ],
      ),
    );
  }
}

/// The standing badge's tile for an avatar of [avatar] px (15 at the
/// pill's 36).
double badgeSize(double avatar) => (avatar * 0.42).clamp(12.0, 19.0);

/// A standing as a small dark tile with a thin dark outline and a muted
/// glyph in its colour, calm over the glass and the picture: a cup for
/// BRB, "Zz" for AFK, an eye with a line through it for Out.
class StateBadge extends StatelessWidget {
  final Presence presence;
  final double size;
  const StateBadge({super.key, required this.presence, required this.size});

  static Color glyphColor(Presence p) => switch (p) {
        Presence.brb => const Color(0xFFE8C77A),
        Presence.afk => const Color(0xFF9FB3C8),
        _ => const Color(0xFFA0A0A8),
      };

  @override
  Widget build(BuildContext context) {
    final color = glyphColor(presence);
    final g = size * 0.68;
    final Widget glyph = switch (presence) {
      Presence.brb => Icon(Icons.coffee_rounded, size: g, color: color),
      Presence.afk => _Zz(size: g, color: color),
      _ => Icon(Icons.visibility_off_rounded, size: g, color: color),
    };
    return Tooltip(
      message: switch (presence) {
        Presence.brb => 'BRB',
        Presence.afk => 'AFK',
        Presence.out => 'Out',
        Presence.watching => '',
      },
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C21),
          borderRadius: BorderRadius.circular(size * 0.3),
          border: Border.all(color: const Color(0xCC000000), width: 1),
        ),
        child: glyph,
      ),
    );
  }
}

/// "Zz": a big z low left and a small one high right.
class _Zz extends StatelessWidget {
  final double size;
  final Color color;
  const _Zz({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    TextStyle st(double f) => TextStyle(fontSize: f, height: 1, fontWeight: FontWeight.w800, color: color);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned(left: size * 0.02, bottom: -size * 0.04, child: Text('z', style: st(size * 0.82))),
          Positioned(right: 0, top: -size * 0.06, child: Text('z', style: st(size * 0.55))),
        ],
      ),
    );
  }
}

/// Over the picture's edge: loading (a white run from the top as long as
/// the buffer is along, gliding to each new value; with nothing known
/// yet, a short white arc going round) or reconnecting (an amber stretch
/// going round), each on a thin dark line so it shows on light pictures.
/// Nothing ever jumps back: the arcs turn on, the run only follows the
/// buffer. Follows the shape: an arc on a circle, a stretch of outline on
/// a rounded square.
class AvatarEdge extends StatefulWidget {
  final RRect shape;
  final Color? edge;
  final AvatarActivity activity;

  /// Loading: the share of the buffer the group needs (null: unknown).
  final double? progress;
  const AvatarEdge({super.key, required this.shape, this.edge, this.activity = AvatarActivity.none, this.progress});

  /// The edge moves; still under `flutter test` (a loop never settles).
  static final bool motion = !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  State<AvatarEdge> createState() => _AvatarEdgeState();
}

class _AvatarEdgeState extends State<AvatarEdge> with TickerProviderStateMixin {
  /// Where the arcs are round the outline (0..1, wrapping).
  late final AnimationController _spin = AnimationController(vsync: this);

  /// The loading run's length (0..1), gliding to the latest buffer.
  late final AnimationController _fill = AnimationController(vsync: this);

  /// A known share is drawn as the run, else the arc.
  bool get _known => widget.progress != null && widget.progress! > 0;

  @override
  void initState() {
    super.initState();
    _fill.value = widget.progress ?? 0;
    _sync();
  }

  @override
  void didUpdateWidget(AvatarEdge old) {
    super.didUpdateWidget(old);
    if (old.activity != widget.activity || old.progress != widget.progress) _sync(from: old);
  }

  void _sync({AvatarEdge? from}) {
    final a = widget.activity;
    // The run follows the buffer.
    final p = widget.progress;
    if (p != null && p != from?.progress) {
      if (AvatarEdge.motion && from?.progress != null) {
        _fill.animateTo(p, duration: const Duration(milliseconds: 600), curve: Curves.easeOutCubic);
      } else {
        _fill.value = p;
      }
    }
    final turning = a == AvatarActivity.reconnecting || (a == AvatarActivity.loading && !_known);
    if (!turning) {
      _spin.stop();
      return;
    }
    if (_spin.isAnimating) return;
    _spin.duration = a == AvatarActivity.loading ? const Duration(milliseconds: 1600) : const Duration(milliseconds: 1400);
    if (AvatarEdge.motion) {
      // Linear and wrapping: one turn runs on into the next.
      _spin.repeat();
    } else {
      _spin.value = 0.6;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _EdgePainter(
          shape: widget.shape,
          edge: widget.edge,
          activity: widget.activity,
          known: _known,
          spin: _spin,
          fill: _fill,
        ),
      );
}

class _EdgePainter extends CustomPainter {
  final RRect shape;
  final Color? edge;
  final AvatarActivity activity;
  final bool known;
  final Animation<double> spin;
  final Animation<double> fill;
  _EdgePainter({
    required this.shape,
    required this.edge,
    required this.activity,
    required this.known,
    required this.spin,
    required this.fill,
  }) : super(repaint: Listenable.merge([spin, fill]));

  static const _stroke = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    // The parting edge itself is a halo behind the picture (StatusAvatar);
    // [edge] here only keeps the activity runs clear of it.
    if (activity == AvatarActivity.none) return;
    // The outline, starting at the top middle and going clockwise.
    final r = shape.deflate(_stroke / 2 + (edge == null ? 0 : 2));
    final metric = _fromTop(r).computeMetrics().first;
    final len = metric.length;
    final Path run;
    final Color color;
    if (activity == AvatarActivity.loading && known) {
      final f = fill.value.clamp(0.0, 1.0);
      if (f <= 0) return;
      run = metric.extractPath(0, len * f);
      color = Colors.white;
    } else {
      // An arc going round; it wraps past the top without a seam.
      final a = len * spin.value, b = a + len * (activity == AvatarActivity.loading ? 0.22 : 0.28);
      run = metric.extractPath(a, math.min(b, len));
      if (b > len) run.addPath(metric.extractPath(0, b - len), Offset.zero);
      color = activity == AvatarActivity.loading ? Colors.white : Colors.amber;
    }
    canvas.drawPath(
        run,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke + 1.5
          ..strokeCap = StrokeCap.round
          ..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawPath(
        run,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  /// [r]'s outline as one path from the top middle, clockwise.
  static Path _fromTop(RRect r) {
    final rad = r.tlRadiusX;
    final p = Path()..moveTo(r.center.dx, r.top);
    p.lineTo(r.right - rad, r.top);
    if (rad > 0) p.arcToPoint(Offset(r.right, r.top + rad), radius: Radius.circular(rad));
    p.lineTo(r.right, r.bottom - rad);
    if (rad > 0) p.arcToPoint(Offset(r.right - rad, r.bottom), radius: Radius.circular(rad));
    p.lineTo(r.left + rad, r.bottom);
    if (rad > 0) p.arcToPoint(Offset(r.left, r.bottom - rad), radius: Radius.circular(rad));
    p.lineTo(r.left, r.top + rad);
    if (rad > 0) p.arcToPoint(Offset(r.left + rad, r.top), radius: Radius.circular(rad));
    p.close();
    return p;
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.shape != shape ||
      old.edge != edge ||
      old.activity != activity ||
      old.known != known ||
      old.spin != spin ||
      old.fill != fill;
}

/// A row of people, host first, then watching, BRB, out, gone. Rounded
/// squares sit side by side; circles overlap (each with an outline in the
/// background colour) and spread apart on hover. "+N" past [shown]. Each
/// avatar is its person's ([PersonHover]: card on hover, pinned by a
/// click).
class AvatarStack extends StatefulWidget {
  final List<AvatarInfo> members;
  /// A click on the stack outside an avatar ("+N"), and the people
  /// cards' "Everyone in the server": the members card.
  final VoidCallback? onTap;
  final int shown;
  final double size;
  /// Each avatar has its person's card (hover shows it, a click pins
  /// it); off: a plain name tooltip.
  final bool people;
  /// Hears a person's card open and close (the player's controls stay up).
  final ValueChanged<bool>? onCard;
  const AvatarStack({
    super.key,
    required this.members,
    this.onTap,
    this.shown = 5,
    this.size = 42,
    this.people = true,
    this.onCard,
  });

  @override
  State<AvatarStack> createState() => _AvatarStackState();
}

class _AvatarStackState extends State<AvatarStack> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => SignalBuilder(builder: (context) => _build(context, AvatarShape.of(context)));

  Widget _build(BuildContext context, AvatarShape shape) {
    final size = widget.size;
    int rank(AvatarInfo m) => m.host ? 0 : (m.gone ? 4 : m.isOut ? 3 : m.brb ? 2 : 1);
    final sorted = [...widget.members]..sort((a, b) => rank(a) - rank(b));
    final visible = sorted.take(widget.shown).toList();
    final extra = sorted.length - visible.length;
    final overlap = shape.circle;
    // Whole pixels: at a fractional offset Impeller smooths the rounded clip
    // on a half-pixel grid and the corners look jagged.
    final step = !overlap || _hover ? size + 8 : (size * 0.62).roundToDouble();
    final count = visible.length + (extra > 0 ? 1 : 0);
    final width = count == 0 ? 0.0 : step * (count - 1) + size;
    Widget avatar(AvatarInfo i) => StatusAvatar(info: i, size: size, edge: overlap && count > 1);
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
                  child: widget.people
                      ? PersonHover(
                          person: PersonRef.of(visible[i]),
                          onEveryone: widget.onTap,
                          onOpen: widget.onCard,
                          child: avatar(visible[i]),
                        )
                      : Tooltip(
                          message: [
                            visible[i].error.isEmpty
                                ? visible[i].name
                                : "${visible[i].name} can't play this: ${visible[i].error}",
                            if (visible[i].delivery.isNotEmpty) visible[i].delivery,
                            if (visible[i].app.isNotEmpty) 'Starsync ${visible[i].app}',
                          ].join('\n'),
                          child: avatar(visible[i]),
                        ),
                ),
              if (extra > 0)
                AnimatedPositioned(
                  duration: easeTime,
                  curve: ease,
                  left: visible.length * step,
                  top: 0,
                  child: Container(
                    width: size,
                    height: size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: shape.radius(size),
                    ),
                    child: Text('+$extra', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
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
  return AvatarInfo(id: id, name: name, color: colorForName(name));
}

/// Someone's avatar in a line that stays up a while (a toast, a danmaku
/// line): [info] as it was when the line came, with their picture looked
/// up again while it is missing. A picture often lands after the line
/// that needs it (the server's copy is fetched once the member is seen,
/// a first fetch can fail and is retried), so a line made a moment too
/// early would otherwise keep the initial for good.
class LineAvatar extends StatelessWidget {
  final AvatarInfo info;
  final double size;
  final bool badges;
  final bool marks;
  const LineAvatar({super.key, required this.info, required this.size, this.badges = false, this.marks = true});

  @override
  Widget build(BuildContext context) {
    Widget avatar(AvatarInfo i) => StatusAvatar(info: i, size: size, badges: badges, marks: marks);
    final graph = AppScope.maybeOf(context);
    if (info.image != null || graph == null) return avatar(info);
    return PartyWatch(builder: (context) {
      final image = avatarForName(info.name, graph.coordinator, info.id).image;
      return avatar(image == null ? info : info.withImage(image));
    });
  }
}
