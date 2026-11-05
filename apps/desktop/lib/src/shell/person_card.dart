import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:sync_relay_core/core.dart';

import '../app/app_graph.dart';
import '../danmaku/danmaku.dart' show DanmakuController, DanmakuItem;
import '../session/delivery.dart';
import '../session/now_playing.dart' show NowPlaying;
import '../session/party.dart';
import '../session/session_coordinator.dart';
import '../widgets/app_menu.dart' show AppGlass;
import 'avatar.dart';
import 'motion.dart';
import 'party_strip.dart' show VersionText, showMembersCard;

// People cards: one card for a person wherever they show (the strip's and
// the fullscreen avatars, the members card's rows, chat lines, toasts,
// danmaku lines). Resting the mouse on them shows it ([PersonHover]), a
// click pins it ([showPersonCard]) until a click outside or Esc. It reads
// the person live from the state: a larger picture (a click shows it full
// size), name, standing, app version, what they pass on, the host crown,
// and their actions (the same as the members card's ⋮).

/// What can be done to a member (the members card's ⋮ and the people
/// card).
enum MemberAction { dontWaitFor, waitFor, nudge, out, join }

/// One member action as menus and buttons show it.
typedef MemberActionView = ({MemberAction action, String label, IconData icon});

/// The first word of [name] for an action's label ("Wait for Bob").
String _short(String name) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  return first.isEmpty ? 'them' : first;
}

/// What [info]'s member offers. Someone else: "Don't wait for Bob" while
/// the group waits for them (BRB, or their video), else "Wait for Bob"
/// (sets their BRB: they ran off without it; their own Space clears it)
/// while they watch; Nudge; Out while they are not. Yourself: Out, or
/// Join while out.
List<MemberActionView> memberActions(AvatarInfo info) {
  final name = _short(info.name);
  final waited = info.brb || info.activity == AvatarActivity.loading;
  return [
    if (!info.self && waited)
      (action: MemberAction.dontWaitFor, label: "Don't wait for $name", icon: Icons.fast_forward_rounded)
    else if (!info.self && !info.isOut && !info.gone)
      (action: MemberAction.waitFor, label: 'Wait for $name', icon: Icons.coffee_rounded),
    if (!info.self) (action: MemberAction.nudge, label: 'Nudge', icon: Icons.notifications_active_outlined),
    if (info.self && info.isOut)
      (action: MemberAction.join, label: 'Join', icon: Icons.login_rounded)
    else if (!info.isOut)
      (action: MemberAction.out, label: 'Out', icon: Icons.visibility_off_rounded),
  ];
}

/// Runs [action] on member [id].
void runMemberAction(SessionCoordinator coord, String id, MemberAction action) {
  switch (action) {
    case MemberAction.dontWaitFor:
      coord.dontWaitFor(id);
    case MemberAction.waitFor:
      coord.waitFor(id);
    case MemberAction.nudge:
      coord.nudgeMember(id);
    case MemberAction.out:
      coord.goOut(id == coord.connection.memberId ? null : id);
    case MemberAction.join:
      coord.join();
  }
}

/// Who a card is about: member [id] when the line has one (names change
/// and repeat), else by [name]; [info] is how the place showing them drew
/// them (used once they left).
@immutable
class PersonRef {
  final String id;
  final String name;
  final AvatarInfo? info;
  const PersonRef({this.id = '', required this.name, this.info});

  PersonRef.of(AvatarInfo i) : this(id: i.id, name: i.name, info: i);
}

/// [p] in the latest state, or null when not in the server.
MemberView? memberOf(PersonRef p, StateBroadcast? r) {
  for (final m in r?.members ?? const <MemberView>[]) {
    if (p.id.isNotEmpty ? m.id == p.id : m.name == p.name) return m;
  }
  return null;
}

/// The standing in words: "Watching", "Loading…", "BRB · 4 min", "AFK ·
/// 12 min", "Out", "Reconnecting (2 min)"; with its dot colour.
(String, Color) presenceText(AvatarInfo i, {DateTime? now}) {
  final at = now ?? DateTime.now().toUtc();
  String since(DateTime? s) => s == null || at.difference(s).inMinutes < 1 ? '' : ' · ${sinceText(s, at)}';
  if (i.gone) {
    final standing = i.presence == Presence.watching ? '' : ' · ${i.presence == Presence.brb ? 'BRB' : 'out'}';
    return ('Reconnecting${i.goneSince == null ? '' : ' (${sinceText(i.goneSince!, at)})'}$standing', Colors.grey.shade500);
  }
  return switch (i.presence) {
    Presence.watching when i.activity == AvatarActivity.loading => ('Loading…', Colors.amber),
    Presence.watching => ('Watching', Colors.greenAccent.shade400),
    Presence.brb => ('BRB${since(i.since)}', const Color(0xFFE8C77A)),
    Presence.afk => ('AFK${since(i.since)}', Colors.blueGrey.shade200),
    Presence.out => ('Out', Colors.grey.shade500),
  };
}

/// The card: its content, live from the state.
class PersonCard extends StatelessWidget {
  static const width = 312.0;
  static const pictureSize = 64.0;

  final PersonRef person;

  /// Shows "Everyone in the server" (not in the members card itself);
  /// [onEveryone] opens it (default: [showMembersCard]).
  final bool everyone;
  final VoidCallback? onEveryone;

  /// After an action or a link: the pinned card closes.
  final VoidCallback? onDone;
  const PersonCard({super.key, required this.person, this.everyone = true, this.onEveryone, this.onDone});

  @override
  Widget build(BuildContext context) => PartyWatch(builder: (context) {
        final coord = AppScope.of(context).coordinator;
        final r = coord.serverState.value;
        final m = memberOf(person, r);
        final info = m == null
            ? (person.info ?? AvatarInfo(id: person.id, name: person.name, color: colorForName(person.name)))
            : memberAvatarInfo(m, r, coord);
        final d = r == null ? null : deliveryOf(r, selfId: coord.connection.memberId, names: coord.memberNames);
        final passes = m != null && d != null && d.sourceId.isNotEmpty && d.sourceId == m.id;
        final now = coord.nowPlaying.value;
        return _CardBody(
          info: info,
          here: m != null,
          passing: passes ? _passing(d, now) : null,
          everyone: everyone && m != null,
          onAction: (a) {
            runMemberAction(coord, info.id, a);
            onDone?.call();
          },
          onEveryone: () {
            onDone?.call();
            (onEveryone ?? () => showMembersCard(Navigator.of(context, rootNavigator: true).context))();
          },
        );
      });

  static (String, String) _passing(Delivery d, NowPlaying? now) {
    final what = now == null ? 'the video' : [now.title, ?now.episode].join(' · ');
    final verb = d.kind == DeliveryKind.hostFile ? 'Hosts' : 'Passing on';
    return ('$verb $what', d.detail);
  }
}

class _CardBody extends StatelessWidget {
  final AvatarInfo info;
  final bool here;
  /// What they pass on and how it flows; null when they do not.
  final (String, String)? passing;
  final bool everyone;
  final ValueChanged<MemberAction> onAction;
  final VoidCallback onEveryone;
  const _CardBody({
    required this.info,
    required this.here,
    required this.passing,
    required this.everyone,
    required this.onAction,
    required this.onEveryone,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final (presence, dot) = presenceText(info);
    final image = info.image;
    Widget fact(Key key, IconData icon, Color color, Widget text) => Padding(
          key: key,
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
            const SizedBox(width: 8),
            Expanded(child: DefaultTextStyle.merge(style: TextStyle(fontSize: 12.5, color: scheme.onSurface), child: text)),
          ]),
        );
    final picture = StatusAvatar(info: info, size: PersonCard.pictureSize);
    return AppGlass(
      key: const ValueKey('person-card'),
      radius: 16,
      child: SizedBox(
        width: PersonCard.width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (image == null)
                    picture
                  else
                    Tooltip(
                      message: 'View picture',
                      waitDuration: const Duration(milliseconds: 500),
                      child: InkWell(
                        key: const ValueKey('person-picture'),
                        borderRadius: AvatarShape.of(context).radius(PersonCard.pictureSize),
                        onTap: () => showPictureView(context, image, info.name),
                        child: MouseRegion(cursor: SystemMouseCursors.zoomIn, child: picture),
                      ),
                    ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: info.name),
                            if (info.self)
                              TextSpan(text: '  you', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: muted)),
                          ]),
                          key: const ValueKey('person-name'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.2),
                        ),
                        const SizedBox(height: 4),
                        Row(children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: here ? dot : Colors.grey.shade700),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              here ? presence : 'Not in the server',
                              key: const ValueKey('person-presence'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: muted),
                            ),
                          ),
                        ]),
                        if (here && (info.host || info.relaying)) ...[
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            if (info.host) const Pill('host', Colors.amber),
                            if (info.relaying) const Pill('passing the video on', Colors.lightBlueAccent),
                          ]),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (here) ...[
                const SizedBox(height: 10),
                Divider(height: 1, thickness: 0.5, color: Colors.white.withValues(alpha: 0.08)),
                const SizedBox(height: 2),
                if (info.error.isNotEmpty)
                  fact(const ValueKey('person-error'), Icons.error_outline_rounded, Colors.redAccent.shade100,
                      Text("Can't play this: ${info.error}")),
                // How it reaches them (the source's line says it instead).
                if (info.delivery.isNotEmpty && passing == null)
                  fact(const ValueKey('person-route'), Icons.alt_route_rounded, muted, Text(info.delivery)),
                if (passing case (final what, final how))
                  fact(
                    const ValueKey('person-passing'),
                    Icons.cell_tower,
                    Colors.lightBlueAccent,
                    Text.rich(TextSpan(children: [
                      TextSpan(text: what),
                      if (how.isNotEmpty) TextSpan(text: '\n$how', style: TextStyle(fontSize: 11.5, color: muted)),
                    ])),
                  ),
                if (info.app.isNotEmpty)
                  fact(
                    const ValueKey('person-app'),
                    Icons.info_outline_rounded,
                    muted,
                    Row(children: [
                      Text('Starsync ', style: TextStyle(fontSize: 12.5, color: muted)),
                      VersionText(version: info.app),
                    ]),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in memberActions(info))
                      _ActionChip(
                        key: ValueKey('person-action-${a.action.name}'),
                        icon: a.icon,
                        label: a.label,
                        onTap: () => onAction(a.action),
                      ),
                  ],
                ),
                if (everyone) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('person-everyone'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5),
                      ),
                      onPressed: onEveryone,
                      icon: const Icon(Icons.groups_outlined, size: 16),
                      label: const Text('Everyone in the server'),
                    ),
                  ),
                ],
              ] else
                const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small rounded action: icon and label on a soft surface.
class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionChip({super.key, required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = BorderRadius.circular(8);
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: Color(0x1FFFFFFF), width: 0.5)),
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// [image] full size over a dim backdrop, the name under it; a click or
/// Esc closes it.
Future<void> showPictureView(BuildContext context, ImageProvider image, String name) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: Colors.black54,
      transitionDuration: easeTime,
      pageBuilder: (context, _, _) {
        final side = math.min(320.0, MediaQuery.sizeOf(context).shortestSide - 96);
        return Material(
          type: MaterialType.transparency,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Center(
              child: Column(
              key: const ValueKey('person-picture-view'),
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 32, offset: Offset(0, 12))],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image(image: image, width: side, height: side, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                  ),
                ),
                const SizedBox(height: 14),
                Text(name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)])),
              ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim, _, child) {
        final a = CurvedAnimation(parent: anim, curve: ease, reverseCurve: Curves.easeIn);
        return FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
        );
      },
    );

/// Pins [person]'s card next to [anchor] (global rect of what was
/// clicked) until a click outside or Esc. [onOpen] hears it open and close
/// (the player's controls stay up meanwhile).
Future<void> showPersonCard(
  BuildContext context,
  PersonRef person,
  Rect anchor, {
  bool everyone = true,
  VoidCallback? onEveryone,
  ValueChanged<bool>? onOpen,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  onOpen?.call(true);
  try {
    await navigator.push(_PersonCardRoute(
      anchor: anchor,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (context) => PersonCard(
        person: person,
        everyone: everyone,
        onEveryone: onEveryone,
        onDone: () => Navigator.of(context).pop(),
      ),
    ));
  } finally {
    onOpen?.call(false);
  }
}

/// Where a card goes for [anchor]: under it when the room below holds
/// it, else over it; its left edge at the anchor's, kept on screen.
class _CardLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  const _CardLayout(this.anchor);

  static const gap = 8.0, margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
      maxWidth: math.max(0.0, c.maxWidth - 2 * margin), maxHeight: math.max(0.0, c.maxHeight - 2 * margin));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final below = anchor.bottom + gap;
    final y = below + child.height <= size.height - margin || anchor.top - gap - child.height < margin
        ? below
        : anchor.top - gap - child.height;
    final x = anchor.left.clamp(margin, math.max(margin, size.width - child.width - margin)).toDouble();
    return Offset(x, y.clamp(margin, math.max(margin, size.height - child.height - margin)).toDouble());
  }

  @override
  bool shouldRelayout(_CardLayout old) => old.anchor != anchor;
}

class _PersonCardRoute extends PopupRoute<void> {
  final Rect anchor;
  final CapturedThemes capturedThemes;
  final WidgetBuilder builder;
  _PersonCardRoute({required this.anchor, required this.capturedThemes, required this.builder});

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final a = CurvedAnimation(parent: animation, curve: ease, reverseCurve: Curves.easeIn);
    return CustomSingleChildLayout(
      delegate: _CardLayout(anchor),
      child: FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(a),
          alignment: Alignment.topLeft,
          child: capturedThemes.wrap(Builder(builder: builder)),
        ),
      ),
    );
  }
}

/// [child] stands for [person]: the mouse resting on it shows their card
/// ([showAfter]), moving into the card keeps it, a click pins it
/// ([showPersonCard]). The same everywhere a person shows. [everyone]:
/// the card links to the members card ([onEveryone] opens it); [onOpen]
/// hears a card open and close.
class PersonHover extends StatefulWidget {
  final PersonRef person;
  final Widget child;
  final bool everyone;
  final VoidCallback? onEveryone;
  final ValueChanged<bool>? onOpen;
  final Duration showAfter;
  const PersonHover({
    super.key,
    required this.person,
    required this.child,
    this.everyone = true,
    this.onEveryone,
    this.onOpen,
    this.showAfter = const Duration(milliseconds: 450),
  });

  /// How long the card stays once the mouse left both it and the person.
  static const hideAfter = Duration(milliseconds: 220);

  @override
  State<PersonHover> createState() => _PersonHoverState();
}

class _PersonHoverState extends State<PersonHover> {
  OverlayEntry? _entry;
  Timer? _show, _hide;
  bool _onPerson = false, _onCard = false, _pinned = false;

  Rect _anchor() {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _enter(PointerEnterEvent _) {
    _onPerson = true;
    _hide?.cancel();
    if (_entry == null && !_pinned) _show = Timer(widget.showAfter, _open);
  }

  void _exit(PointerExitEvent _) {
    _onPerson = false;
    _show?.cancel();
    _later();
  }

  void _later() {
    _hide?.cancel();
    _hide = Timer(PersonHover.hideAfter, () {
      if (!_onPerson && !_onCard) _close();
    });
  }

  void _open() {
    if (!mounted || _entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final anchor = _anchor();
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    widget.onOpen?.call(true);
    _entry = OverlayEntry(
      builder: (_) => CustomSingleChildLayout(
        delegate: _CardLayout(anchor),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 180),
          curve: ease,
          builder: (context, v, child) => Opacity(
            opacity: v,
            child: Transform.scale(scale: 0.96 + 0.04 * v, alignment: Alignment.topLeft, child: child),
          ),
          child: MouseRegion(
            onEnter: (_) {
              _onCard = true;
              _hide?.cancel();
            },
            onExit: (_) {
              _onCard = false;
              _later();
            },
            child: GestureDetector(
              key: const ValueKey('person-card-hover'),
              onTap: _pin,
              child: themes.wrap(PersonCard(
                person: widget.person,
                everyone: widget.everyone,
                onEveryone: widget.onEveryone,
                onDone: _close,
              )),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _close() {
    _show?.cancel();
    _hide?.cancel();
    final e = _entry;
    if (e == null) return;
    _entry = null;
    _onCard = false;
    e.remove();
    e.dispose();
    widget.onOpen?.call(false);
  }

  Future<void> _pin() async {
    if (_pinned || !mounted) return;
    final anchor = _anchor();
    _close();
    _pinned = true;
    try {
      await showPersonCard(context, widget.person, anchor,
          everyone: widget.everyone, onEveryone: widget.onEveryone, onOpen: widget.onOpen);
    } finally {
      _pinned = false;
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: _enter,
        onExit: _exit,
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pin,
          child: widget.child,
        ),
      );
}

/// Over the picture, around the controls: a click on a flying danmaku
/// line's sender (avatar and name) pins their card. Every event still
/// reaches [child] (the controls); lines move too fast to rest the mouse
/// on, so they have no hover card.
class DanmakuPersonTaps extends SingleChildRenderObjectWidget {
  final DanmakuController lines;
  final void Function(DanmakuItem item, Rect rect) onTap;
  const DanmakuPersonTaps({super.key, required this.lines, required this.onTap, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderDanmakuTaps(lines, onTap);

  @override
  void updateRenderObject(BuildContext context, RenderDanmakuTaps renderObject) => renderObject
    ..lines = lines
    ..onTap = onTap;
}

class RenderDanmakuTaps extends RenderProxyBox {
  DanmakuController lines;
  void Function(DanmakuItem item, Rect rect) onTap;
  RenderDanmakuTaps(this.lines, this.onTap);

  @override
  bool hitTestSelf(Offset position) => lines.senderAt(localToGlobal(position)) != null;

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is! PointerDownEvent || event.buttons != kPrimaryButton) return;
    final hit = lines.senderAt(event.position);
    if (hit != null) onTap(hit.item, hit.rect);
  }
}
