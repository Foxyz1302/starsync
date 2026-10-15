import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fox_utils/fox_utils.dart' show ClipboardX, DesktopDropX, DropTarget;
import 'package:leaf_widgets/leaf_widgets.dart' show LeafPopover, LeafPopoverController;
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../controls/controls_probe.dart' show ControlsHold;
import '../controls/minimal/style.dart';
import '../files/scanner.dart' show FileKind, kindOf;
import '../jellyfin/images.dart';
import '../jellyfin/session_media.dart' show EpisodeLink;
import '../screens/home/picked_media.dart';
import '../session/session_coordinator.dart' show autoAdvanceSecs;
import '../shell/avatar.dart';
import '../shell/handoff.dart' show handoffHolds;
import '../shell/library_link.dart' show LinkPreview, cachedLinkPreview;
import '../shell/motion.dart';
import '../state/session_state.dart';
import '../widgets/app_menu.dart' show AppGlass, AppMenuItem, AppMenuStyle, showAppMenu;
import '../widgets/copy_open.dart';
import '../widgets/text_focus.dart' show KeyboardClaim;
import 'queue_controller.dart';
import 'queue_logic.dart';

// Up next in the player: its control in the top bar (with the window
// controls), the popover it opens (the queue, the continuation, a field
// and a drop zone to add), and the end-of-media card for the first item.


// ---------------------------------------------------------------- button

/// Which controls skin the Up next control sits in: it takes the look
/// of that bar's buttons.
enum UpNextLook { standard, minimal }

/// The next item's picture, "UP NEXT" over its title, a +n count and ⏭
/// (play it now) in the player's top bar, one flat control among its
/// buttons; the title opens the queue, resting on it shows a preview card.
/// Without Up next, the continuation ("NEXT · S1 E8" over its name, ⏭
/// plays it). Nothing when both are empty.
class UpNextButton extends StatefulWidget {
  final QueueController queue;
  /// Plays the continuation's first episode (the next episode).
  final VoidCallback onPlayNextEpisode;
  final UpNextLook look;
  /// Held while the preview card is up, so the controls stay up with it.
  final ControlsHold? hold;
  const UpNextButton(
      {super.key, required this.queue, required this.onPlayNextEpisode, required this.look, this.hold});

  @override
  State<UpNextButton> createState() => _UpNextButtonState();
}

class _UpNextButtonState extends State<UpNextButton> {
  final _popover = LeafPopoverController();
  final _preview = OverlayPortalController();
  final _link = LayerLink();
  Timer? _previewTimer;
  bool _hoverTitle = false;

  QueueController get _q => widget.queue;
  bool get _minimal => widget.look == UpNextLook.minimal;

  @override
  void didUpdateWidget(UpNextButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hold != widget.hold) {
      oldWidget.hold?.set(this, false);
      widget.hold?.set(this, _preview.isShowing);
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    widget.hold?.set(this, false);
    if (_q.popoverOpen.peek()) {
      _q.popoverOpen.value = false;
      handoffHolds = math.max(0, handoffHolds - 1);
    }
    super.dispose();
  }

  void _toggle() {
    _hidePreview();
    if (_popover.isShowing) {
      _popover.hide();
      return;
    }
    _q.coord.markInput();
    _q.popoverOpen.value = true;
    handoffHolds++;
    _popover.show();
  }

  void _closed() {
    if (!_q.popoverOpen.peek()) return;
    _q.popoverOpen.value = false;
    handoffHolds = math.max(0, handoffHolds - 1);
  }

  // The preview: up after resting on the title a moment (never with the
  // popover open), down shortly after the mouse left both it and the
  // title, so the mouse can cross the gap. While up it holds the controls.
  void _previewSoon() {
    _previewTimer?.cancel();
    if (_preview.isShowing || _q.popoverOpen.peek()) return;
    _previewTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || _q.popoverOpen.peek()) return;
      _preview.show();
      widget.hold?.set(this, true);
    });
  }

  void _keepPreview() => _previewTimer?.cancel();

  void _leave() {
    _previewTimer?.cancel();
    if (!_preview.isShowing) return;
    _previewTimer = Timer(const Duration(milliseconds: 200), _hidePreview);
  }

  void _hidePreview() {
    _previewTimer?.cancel();
    if (_preview.isShowing) _preview.hide();
    widget.hold?.set(this, false);
  }

  @override
  Widget build(BuildContext context) {
    // The bar's own metrics: the Minimal skin's rounded squares, or the
    // Standard skin's round 44 px icon buttons.
    final height = _minimal ? MinimalStyle.button + 2 * MinimalStyle.capsulePad : 44.0;
    final radius = _minimal ? MinimalStyle.radius + MinimalStyle.capsulePad : height / 2;
    final hover = _minimal ? MinimalStyle.hover : Colors.white10;
    final fontSize = _minimal ? MinimalStyle.fontSize : 14.0;
    final dim = _minimal ? MinimalStyle.dim : Colors.white70;
    // The picture fills the button's height but for a 7 px margin.
    final thumbWidth = (height - 14) * 16 / 9;
    final thumbRadius = _minimal ? MinimalStyle.radius - 4 : 6.0;
    return SignalBuilder(builder: (context) {
      final items = _q.items.value;
      final cont = _q.shownContinuation.value;
      final open = _q.popoverOpen.value;
      if (items.isEmpty && cont.isEmpty && !open) {
        // Gone with the preview up: let go of the controls.
        if (_preview.isShowing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _hidePreview();
          });
        }
        return const SizedBox.shrink();
      }
      final queued = items.isNotEmpty;
      final item = items.firstOrNull;
      final episode = cont.firstOrNull;
      final more = items.length - 1;
      final String kicker;
      final String title;
      final Widget thumb;
      if (item != null) {
        kicker = 'UP NEXT';
        title = item.title;
        thumb = QueueThumb(queue: _q, item: item, width: thumbWidth, radius: thumbRadius);
      } else if (episode != null) {
        final n = episodeNumbers(episode.item);
        kicker = n == null ? 'NEXT' : 'NEXT  ·  $n';
        title = episode.item.name;
        thumb = _EpisodeThumb(queue: _q, episode: episode, width: thumbWidth, radius: thumbRadius);
      } else {
        kicker = 'UP NEXT';
        title = 'Nothing yet';
        thumb = _BlankThumb(icon: Icons.queue_play_next_rounded, width: thumbWidth, radius: thumbRadius);
      }
      final label = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          setState(() => _hoverTitle = true);
          _previewSoon();
        },
        onExit: (_) {
          setState(() => _hoverTitle = false);
          _leave();
        },
        child: GestureDetector(
          key: const ValueKey('up-next-button'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: height,
            // The picture clears a round button's curve.
            padding: EdgeInsets.only(left: _minimal ? 7 : 12, right: 6),
            decoration: BoxDecoration(
              color: _hoverTitle || open ? hover : Colors.transparent,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                thumb,
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kicker,
                          maxLines: 1,
                          style: TextStyle(
                              color: dim, fontSize: 10, height: 1.2, letterSpacing: 0.8, fontWeight: FontWeight.w600)),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: queued ? Colors.white : Colors.white.withValues(alpha: 0.85),
                            fontSize: fontSize,
                            height: 1.25,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                if (more > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: MinimalStyle.hover, borderRadius: BorderRadius.circular(999)),
                    child: Text('+$more', style: TextStyle(color: dim, fontSize: 11)),
                  ),
                ],
                const SizedBox(width: 2),
                AnimatedRotation(
                  duration: easeTime,
                  curve: ease,
                  turns: open ? 0.5 : 0,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: dim),
                ),
              ],
            ),
          ),
        ),
      );
      final playTip = queued
          ? 'Play ${item!.title} now  ($playNextKeys)'
          : 'Play ${episode == null ? '' : episode.label} now  ($playNextKeys)';
      final VoidCallback? play = queued ? _q.skip : (episode != null ? widget.onPlayNextEpisode : null);
      final playButton = _minimal
          ? MinimalButton(key: const ValueKey('up-next-play'), icon: Icons.skip_next_rounded, tooltip: playTip, onPressed: play)
          : Tooltip(
              message: playTip,
              waitDuration: const Duration(milliseconds: 500),
              child: IconButton(
                key: const ValueKey('up-next-play'),
                iconSize: 28,
                color: Colors.white,
                onPressed: play,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            );
      // The popover and the preview hang under the whole control, right
      // edges aligned.
      return LeafPopover(
        controller: _popover,
        popoverAnchor: Alignment.topRight,
        childAnchor: Alignment.bottomRight,
        spacing: 8,
        onDismissed: _closed,
        popoverBuilder: (context, c) => QueuePanel(queue: _q, onClose: c.hide),
        child: OverlayPortal(
          controller: _preview,
          overlayChildBuilder: (context) => Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 8),
              child: MouseRegion(
                onEnter: (_) => _keepPreview(),
                onExit: (_) => _leave(),
                child: GestureDetector(onTap: _toggle, child: UpNextPreview(queue: _q)),
              ),
            ),
          ),
          child: CompositedTransformTarget(
            link: _link,
            // A little apart from the bar's other buttons: its own group.
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [label, if (play != null) playButton],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// The keys that play Up next (else the next episode) now.
const playNextKeys = '> or Shift+N';

/// "S1 E8" for an episode with both numbers, else null.
String? episodeNumbers(JellyfinItem e) =>
    e.parentIndexNumber != null && e.indexNumber != null ? 'S${e.parentIndexNumber} E${e.indexNumber}' : null;

/// What the Up next control shows while the mouse rests on it: the first
/// item (or the next episode) larger, with everything known about it, how
/// ready it is and the keys that play it.
class UpNextPreview extends StatelessWidget {
  final QueueController queue;
  const UpNextPreview({super.key, required this.queue});

  static const _width = 320.0;
  static const _pad = 12.0;
  static const _kicker =
      TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600);
  static const _title = TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.25);
  static const _sub = TextStyle(color: Colors.white60, fontSize: 12, height: 1.3);

  @override
  Widget build(BuildContext context) {
    return AppGlass(
      key: const ValueKey('up-next-preview'),
      child: SizedBox(
        width: _width,
        child: Padding(
          padding: const EdgeInsets.all(_pad),
          child: SignalBuilder(builder: (context) {
            final item = queue.items.value.firstOrNull;
            final episode = queue.shownContinuation.value.firstOrNull;
            final warm = queue.warm.value;
            const picture = _width - 2 * _pad;
            if (item != null) {
              final r = queue.coord.serverState.value;
              final selfId = queue.coord.sync.memberId;
              final more = queue.items.value.length - 1;
              final ready = warm?.id == item.id ? warm!.state : null;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  QueueThumb(queue: queue, item: item, width: picture, radius: 8),
                  const SizedBox(height: 10),
                  Text(more > 0 ? 'UP NEXT  ·  $more MORE AFTER IT' : 'UP NEXT', style: _kicker),
                  const SizedBox(height: 3),
                  Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _title),
                  if (item.sub.isNotEmpty)
                    Text(item.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: _sub),
                  const SizedBox(height: 6),
                  _MetaLine(item: item, members: r?.members ?? const [], selfId: selfId, wrap: true),
                  _footer(ready, ready == null ? performerNote(queue, item, r) : null),
                ],
              );
            }
            if (episode == null) return const SizedBox.shrink();
            final n = episodeNumbers(episode.item);
            final runtime = episode.pick.runtime;
            final sub = [episode.item.seriesName ?? '', if (runtime != null) queueClock(runtime.inSeconds.toDouble())]
                .where((s) => s.isNotEmpty)
                .join('  ·  ');
            final overview = episode.item.overview?.trim() ?? '';
            final ready = warm?.id == 'next:${episode.item.id}' ? warm!.state : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _EpisodeThumb(queue: queue, episode: episode, width: picture, radius: 8),
                const SizedBox(height: 10),
                Text(n == null ? 'NEXT EPISODE' : 'NEXT EPISODE  ·  $n', style: _kicker),
                const SizedBox(height: 3),
                Text(episode.item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: _title),
                if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: _sub),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(overview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.35)),
                ],
                _footer(ready, null),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// How ready it is here (or who puts it up), and the keys that play it.
  Widget _footer(WarmState? ready, String? note) {
    const style = TextStyle(color: Colors.white60, fontSize: 12);
    final (text, color) = switch (ready) {
      WarmState.idle => ('Waiting to get ready', Colors.white54),
      WarmState.warming => ('Getting ready…', Colors.white70),
      WarmState.ready => ('Ready to play', Colors.greenAccent.shade200),
      WarmState.failed => ("Couldn't get it ready", Colors.redAccent.shade100),
      null => (note ?? '', Colors.white54),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          if (ready != null) ...[_WarmDot(state: ready), const SizedBox(width: 6)],
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.copyWith(color: color)),
          ),
          const Text('Play now', style: style),
          const SizedBox(width: 6),
          const _KeyCap('>'),
        ],
      ),
    );
  }
}

/// A key as printed on the keyboard, small.
class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap(this.label);

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppMenuStyle.border, width: 0.5),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600, height: 1.3)),
      );
}

/// Another app puts [item] up: "Bob puts it up"; null when this one does.
String? performerNote(QueueController queue, QueueItem item, StateBroadcast? r) {
  if (r == null) return null;
  final id = queuePerformer(item, r.members).id;
  if (id == null || id == queue.coord.sync.memberId) return null;
  final name = r.members.where((m) => m.id == id).firstOrNull?.name;
  return name == null ? null : '$name puts it up';
}

/// The neutral picture placeholder of the queue (a faint box, an icon).
class _BlankThumb extends StatelessWidget {
  final IconData icon;
  final double width;
  final double radius;
  const _BlankThumb({required this.icon, required this.width, this.radius = 6});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: width,
          height: width * 9 / 16,
          child: _blank(icon, width),
        ),
      );
}

Widget _blank(IconData icon, double width) => ColoredBox(
      color: const Color(0x1FFFFFFF),
      child: Center(child: Icon(icon, size: (width / 4).clamp(12, 32), color: Colors.white38)),
    );

/// An episode's still (else the series' thumb), 16:9 and rounded.
class _EpisodeThumb extends StatelessWidget {
  final QueueController queue;
  final EpisodeLink episode;
  final double width;
  final double radius;
  const _EpisodeThumb({required this.queue, required this.episode, required this.width, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final client = queue.coord.jellyfin.clientFor(e.pick.serverId);
    final image = e.item.ownImage(JellyfinImageType.primary) ?? e.item.image(JellyfinImageType.thumb);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: client == null
            ? _blank(Icons.tv_rounded, width)
            : JellyfinImage(client: client, image: image, placeholder: _blank(Icons.tv_rounded, width)),
      ),
    );
  }
}

class _RoundIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;
  final Color color;
  const _RoundIcon(
      {super.key, required this.icon, required this.tooltip, required this.onPressed, this.size = 20, this.color = Colors.white});

  @override
  State<_RoundIcon> createState() => _RoundIconState();
}

class _RoundIconState extends State<_RoundIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: widget.size + 16,
              height: widget.size + 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hover ? const Color(0x24FFFFFF) : Colors.transparent,
              ),
              child: Icon(widget.icon, size: widget.size, color: widget.color),
            ),
          ),
        ),
      );
}

// ----------------------------------------------------------------- panel

/// The queue, under the chip: Up next (drag to reorder, ▶ / × on hover,
/// right-click for more), "Continues with" (greyed, + adds one), and ways
/// to add: Ctrl+V anywhere in it adds the clipboard's link (or video
/// files), "+ Add link" opens a small field, and links and video files can
/// be dropped on it. What is being added shows as a row of its own (the
/// link's title and picture while it resolves, then "Added", or why not).
class QueuePanel extends StatefulWidget {
  final QueueController queue;
  final VoidCallback onClose;
  /// Tests: the clipboard instead of the system's (files, then text).
  final Future<({List<String> files, String? text})> Function()? readClipboard;
  /// Tests: the preview of a link being added.
  final Future<LinkPreview?> Function(String url)? preview;
  const QueuePanel({super.key, required this.queue, required this.onClose, this.readClipboard, this.preview});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

/// Something being added from the popover: its link's preview while it
/// resolves, then done or why not.
class _Adding {
  final int id;
  final String label;
  LinkPreview? preview;
  String? error;
  bool done = false;
  _Adding(this.id, this.label);
}

class _QueuePanelState extends State<QueuePanel> {
  /// The panel's own focus: the player's keys and Space rest while it has
  /// it ([KeyboardClaim]), Ctrl+V lands here.
  final _focus = FocusNode(debugLabel: 'queue-panel');
  final _field = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'queue-add-field');
  /// "+ Add link" opened the field.
  bool _typing = false;
  final _adding = <_Adding>[];
  int _addingIds = 0;
  /// A paste or drop with nothing to add.
  String? _error;
  bool _dragging = false;
  // Reordered here before the server's state says so (no jump back while
  // it travels).
  List<String>? _order;
  DateTime? _orderAt;

  QueueController get _q => widget.queue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// Back to the panel (after a menu, or the field closing), so its keys
  /// keep working.
  void _refocus() {
    if (mounted) _focus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.keyV &&
        (keys.isControlPressed || keys.isMetaPressed) &&
        !keys.isShiftPressed &&
        !keys.isAltPressed) {
      // Typing a link: an ordinary paste into it.
      if (_fieldFocus.hasFocus && _field.text.isNotEmpty) return KeyEventResult.ignored;
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    // Esc in the field closes the field; else the popover's own (it fades out).
    if (e.logicalKey == LogicalKeyboardKey.escape && _typing) {
      _closeField();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<({List<String> files, String? text})> _readClipboard() async {
    var files = const <String>[];
    String? text;
    try {
      files = await ClipboardX.readFiles();
    } catch (_) {}
    if (files.isEmpty) {
      try {
        text = await ClipboardX.readText();
      } catch (_) {}
    }
    return (files: files, text: text);
  }

  /// Ctrl+V: the clipboard's video files, else the links in its text.
  Future<void> _paste() async {
    final clip = await (widget.readClipboard ?? _readClipboard)();
    final picks = _picksFrom([...clip.files, ...?clip.text?.split(RegExp(r'\s+'))]);
    if (!mounted) return;
    if (picks.isEmpty) {
      setState(() => _error = 'Nothing to add: copy a link (http:// or https://) or a video file');
      return;
    }
    if (_typing && _field.text.isEmpty) _closeField();
    _add(picks);
  }

  /// Links (passed on "through me", like the Link page; alone: direct) and
  /// video files among [raw], once each.
  List<PickedMedia> _picksFrom(Iterable<String> raw) {
    final seen = <String>{};
    final picks = <PickedMedia>[];
    for (final r in raw) {
      final p = r.trim();
      if (p.isEmpty || !seen.add(p)) continue;
      if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(p)) {
        picks.add(LinkMedia(p, relay: LinkRelay.me));
      } else if (kindOf(p) == FileKind.video) {
        picks.add(FileMedia(p));
      }
    }
    return picks;
  }

  /// Adds [picks] in order, each shown as a row until it is in (or why
  /// not).
  Future<void> _add(List<PickedMedia> picks) async {
    setState(() {
      _error = null;
      _adding.removeWhere((a) => a.error != null);
    });
    final rows = [for (final p in picks) _Adding(_addingIds++, p.label)];
    setState(() => _adding.addAll(rows));
    for (final (i, p) in picks.indexed) {
      final row = rows[i];
      if (p case LinkMedia(:final url)) {
        // Its title and picture while it resolves (at once when seen before).
        unawaited((widget.preview ?? cachedLinkPreview)(url).then((v) {
          if (mounted) setState(() => row.preview = v);
        }, onError: (Object _) {}));
      }
      String? error;
      try {
        error = await _q.add(p);
      } catch (e) {
        error = '$e';
      }
      if (!mounted) return;
      setState(() {
        row.error = error;
        row.done = error == null;
      });
      if (error == null) {
        // The item itself shows up in the list; this row goes shortly after.
        Timer(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _adding.remove(row));
        });
      }
    }
  }

  void _openField() {
    setState(() {
      _typing = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  void _closeField() {
    setState(() {
      _typing = false;
      _field.clear();
    });
    _refocus();
  }

  void _submit() {
    final text = _field.text.trim();
    if (text.isEmpty) return;
    final picks = _picksFrom(text.split(RegExp(r'\s+'))).whereType<LinkMedia>().toList();
    if (picks.isEmpty) {
      setState(() => _error = 'Type or paste a link (http:// or https://)');
      return;
    }
    _closeField();
    _add(picks);
  }

  void _dropped(List<String> paths) {
    final picks = _picksFrom(paths);
    if (picks.isEmpty) {
      setState(() => _error = 'Drop a video file or a link');
      return;
    }
    _add(picks);
  }

  /// Right-click on a queued row: Play now, Remove, Copy title, and with
  /// its link known here ([QueueController.linkOf]) Copy link and Open in
  /// browser; a Jellyfin item on a server linked here, Open in Jellyfin.
  Future<void> _rowMenu(BuildContext context, QueueItem item) async {
    final link = _q.linkOf(item);
    final page = _q.jellyfinPageOf(item);
    final pick = await showAppMenu<String>(context, items: [
      const AppMenuItem(value: 'play', label: 'Play now'),
      const AppMenuItem(value: 'remove', label: 'Remove'),
      const AppMenuItem(value: 'title', label: ReuseText.copyTitle),
      if (link != null) ...const [
        AppMenuItem(value: 'link', label: ReuseText.copyLink),
        AppMenuItem(value: 'open', label: ReuseText.openInBrowser),
      ],
      if (page != null) const AppMenuItem(value: 'jellyfin', label: ReuseText.openInJellyfin),
    ]);
    _refocus();
    switch (pick) {
      case 'play':
        _q.playNow(item.id);
      case 'remove':
        _q.remove(item.id);
      case 'title':
        await copyToClipboard(item.title, done: 'Title copied');
      case 'link':
        await copyToClipboard(link!, done: 'Link copied');
      case 'open':
        await openLink(link!);
      case 'jellyfin':
        await openLink(page!);
    }
  }

  List<QueueItem> _ordered(List<QueueItem> items) {
    final order = _order;
    if (order == null) return items;
    final ids = [for (final q in items) q.id];
    final stale = _orderAt == null || DateTime.now().difference(_orderAt!) > const Duration(seconds: 3);
    if (stale || ids.length != order.length || !ids.every(order.contains) || _sameOrder(ids, order)) {
      _order = null;
      return items;
    }
    final byId = {for (final q in items) q.id: q};
    return [for (final id in order) byId[id]!];
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// [to] counts without the moved item (`onReorderItem`).
  void _reorder(List<QueueItem> shown, int from, int to) {
    if (to == from) return;
    final ids = [for (final q in shown) q.id];
    final id = ids.removeAt(from);
    ids.insert(to, id);
    setState(() {
      _order = ids;
      _orderAt = DateTime.now();
    });
    _q.move(id, to);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final drop = DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _dropped(DesktopDropX.pathsOf(d.files));
      },
      // Esc: the popover's own (it fades out).
      child: Builder(
        builder: (context) => SizedBox(
          width: 424,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(260, math.min(600, height - 140))),
            child: AppGlass(
              child: AnimatedContainer(
                duration: easeTime,
                curve: ease,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppMenuStyle.radius),
                  border: Border.all(
                      color: _dragging ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 1.5),
                ),
                child: SignalBuilder(builder: (context) {
                  final items = _ordered(_q.items.value);
                  final cont = _q.shownContinuation.value;
                  final warm = _q.warm.value;
                  final r = _q.coord.serverState.value;
                  final selfId = _q.coord.sync.memberId;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(items.length),
                      Flexible(
                        child: items.isEmpty && cont.isEmpty && _adding.isEmpty
                            ? _empty()
                            : ListView(
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                                children: [
                                  if (items.isEmpty && _adding.isNotEmpty)
                                    const SizedBox.shrink()
                                  else if (items.isEmpty)
                                    const Padding(
                                      padding: EdgeInsets.fromLTRB(12, 2, 12, 8),
                                      child: Text('Nothing added yet. What plays next is below.',
                                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                                    )
                                  else
                                    ReorderableListView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      buildDefaultDragHandles: false,
                                      itemCount: items.length,
                                      proxyDecorator: (child, _, anim) => AnimatedBuilder(
                                        animation: anim,
                                        builder: (context, child) => Material(
                                          color: Colors.transparent,
                                          elevation: 8 * Curves.easeOut.transform(anim.value),
                                          shadowColor: Colors.black,
                                          borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
                                          child: child,
                                        ),
                                        child: child,
                                      ),
                                      onReorderItem: (from, to) => _reorder(items, from, to),
                                      itemBuilder: (context, i) {
                                        final item = items[i];
                                        return _QueueRow(
                                          key: ValueKey(item.id),
                                          index: i,
                                          item: item,
                                          queue: _q,
                                          members: r?.members ?? const [],
                                          selfId: selfId,
                                          warm: i == 0 && warm?.id == item.id ? warm!.state : null,
                                          onMenu: _rowMenu,
                                        );
                                      },
                                    ),
                                  for (final a in _adding)
                                    _AddingRow(
                                      key: ValueKey('queue-adding-${a.id}'),
                                      adding: a,
                                      onDismiss: () => setState(() => _adding.remove(a)),
                                    ),
                                  if (cont.isNotEmpty) ..._continuation(cont, items.isEmpty && _adding.isEmpty),
                                ],
                              ),
                      ),
                      _footer(),
                    ],
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
    return KeyboardClaim(child: Focus(focusNode: _focus, onKeyEvent: _key, child: drop));
  }

  // Text lines up with the rows' (4 panel + 12 row padding).
  Widget _header(int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 6, 4),
        child: Row(
          children: [
            const Text('Up next', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(color: AppMenuStyle.focus, borderRadius: BorderRadius.circular(999)),
                child: Text('$count', style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ),
            ],
            const Spacer(),
            _RoundIcon(icon: Icons.close_rounded, size: 18, color: Colors.white60, tooltip: 'Close (Esc)', onPressed: widget.onClose),
          ],
        ),
      );

  Widget _empty() => const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_play_next_rounded, size: 34, color: Colors.white30),
            SizedBox(height: 10),
            Text('Nothing up next', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text(
              'Press Ctrl+V to add a copied link, drop a video or a link here, or pick "Add to queue" '
              'in the library. It plays when this one ends.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.35),
            ),
          ],
        ),
      );

  List<Widget> _continuation(List<EpisodeLink> cont, bool alone) => [
        Padding(
          padding: EdgeInsets.fromLTRB(12, alone ? 0 : 8, 2, 0),
          child: Row(
            children: [
              const Text('CONTINUES WITH',
                  style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                key: const ValueKey('queue-clear-continuation'),
                style: TextButton.styleFrom(foregroundColor: Colors.white54, visualDensity: VisualDensity.compact),
                onPressed: _q.clearContinuation,
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        for (final e in cont) _ContinuationRow(episode: e, queue: _q),
      ];

  // "+ Add link" (Ctrl+V and drops work without it), or the small field
  // it opens; under it what a paste or drop could not use.
  Widget _footer() {
    final accent = Theme.of(context).colorScheme.primary;
    final Widget row;
    if (_typing) {
      row = TextField(
        key: const ValueKey('queue-add-field'),
        controller: _field,
        focusNode: _fieldFocus,
        style: const TextStyle(fontSize: 13),
        onSubmitted: (_) => _submit(),
        // The app's field look (as `AppSelect`): a faint fill, a hairline,
        // the accent while focused.
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: const Color(0x0DFFFFFF),
          hintText: 'https://…  (Enter adds)',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          prefixIcon: const Icon(Icons.add_link_rounded, size: 16, color: Colors.white54),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          suffixIcon: _RoundIcon(
            icon: Icons.close_rounded,
            size: 16,
            color: Colors.white54,
            tooltip: 'Close (Esc)',
            onPressed: _closeField,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
            borderSide: const BorderSide(color: AppMenuStyle.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
            borderSide: BorderSide(color: accent.withValues(alpha: 0.6), width: 0.5),
          ),
        ),
      );
    } else {
      row = Row(
        children: [
          TextButton.icon(
            key: const ValueKey('queue-add-link'),
            onPressed: _openField,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius)),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add link', style: TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Text(
                _dragging ? 'Drop to add' : 'Ctrl+V pastes · drop here',
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _dragging ? accent : Colors.white38, fontSize: 12),
              ),
            ),
          ),
        ],
      );
    }
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppMenuStyle.border, width: 0.5))),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          AnimatedSize(
            duration: easeTime,
            curve: ease,
            alignment: Alignment.topCenter,
            child: _error == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
                    child: Text(_error!,
                        key: const ValueKey('queue-add-error'),
                        style: TextStyle(color: Colors.orange.shade300, fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A link or file being added from the popover, in the rows' metrics: the
/// link's picture and title as soon as they are known, then "Added" (the
/// row leaves shortly after) or why not (× dismisses it).
class _AddingRow extends StatelessWidget {
  final _Adding adding;
  final VoidCallback onDismiss;
  const _AddingRow({super.key, required this.adding, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final a = adding;
    final p = a.preview;
    final thumb = p?.thumbnail;
    final error = a.error;
    final Widget status;
    if (error != null) {
      status = Text(error,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.orange.shade300, fontSize: 12));
    } else if (a.done) {
      status = const Row(children: [
        Icon(Icons.check_rounded, size: 14, color: Color(0xFF7CF29C)),
        SizedBox(width: 4),
        Text('Added', style: _subStyle),
      ]);
    } else {
      status = const Row(children: [
        SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white54)),
        SizedBox(width: 6),
        Text('Adding…', style: _subStyle),
      ]);
    }
    return AnimatedOpacity(
      duration: easeTime,
      opacity: a.done ? 0.6 : 1,
      child: SizedBox(
        height: queueRowHeight,
        child: Row(
          children: [
            const SizedBox(width: _lead),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: _thumb,
                height: _thumb * 9 / 16,
                child: thumb == null
                    ? _blank(Icons.link_rounded, _thumb)
                    : Image.network(thumb,
                        fit: BoxFit.cover, errorBuilder: (_, _, _) => _blank(Icons.link_rounded, _thumb)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(p?.title ?? a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
                  const SizedBox(height: 2),
                  status,
                ],
              ),
            ),
            if (error != null)
              _RoundIcon(
                icon: Icons.close_rounded,
                size: 18,
                color: Colors.white70,
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ rows

/// A picture of a queued item (by hash from the server), 16:9 and rounded;
/// an icon for how it plays until it arrives (or when it has none).
class QueueThumb extends StatelessWidget {
  final QueueController queue;
  final QueueItem item;
  final double width;
  final double radius;
  const QueueThumb({super.key, required this.queue, required this.item, this.width = 72, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: ListenableBuilder(
          listenable: queue.thumbs,
          builder: (context, _) {
            final bytes = queue.thumbs.bytesFor(item.thumb);
            if (bytes == null) return _blank(howIcon(item.how), width);
            return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium);
          },
        ),
      ),
    );
  }
}

/// The icon for how an item plays (as on the Link page).
IconData howIcon(QueueHow how) => switch (how) {
      QueueHow.through => Icons.cell_tower_rounded,
      QueueHow.server => Icons.dns_rounded,
      QueueHow.direct => Icons.groups_rounded,
      QueueHow.jellyfin => Icons.video_library_rounded,
      QueueHow.file => Icons.insert_drive_file_rounded,
    };

/// Who added it: their picture (still here) or initial, and name.
AvatarInfo _adderAvatar(QueueItem item, List<MemberView> members) {
  final coord = SessionState.instance.coordinator;
  for (final m in members) {
    if (m.id == item.by) return memberAvatarInfo(m, coord.serverState.peek(), coord);
  }
  final name = item.byName.isEmpty ? '?' : item.byName;
  return AvatarInfo(name: name, color: colorForName(name));
}

/// "24:10 · added by ◉ Foxyz · ⌁ through Foxyz".
class _MetaLine extends StatelessWidget {
  final QueueItem item;
  final List<MemberView> members;
  final String selfId;
  final double fontSize;
  /// Wraps onto a second line instead of cutting the end off.
  final bool wrap;
  const _MetaLine(
      {required this.item, required this.members, required this.selfId, this.fontSize = 12, this.wrap = false});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: Colors.white54, fontSize: fontSize);
    final dur = queueClock(item.duration);
    final mine = item.by == selfId && selfId.isNotEmpty;
    final name = mine ? 'you' : (item.byName.isEmpty ? '?' : item.byName);
    final dot = Text('  ·  ', style: TextStyle(color: Colors.white24, fontSize: fontSize));
    if (wrap) {
      final how = queueHowLabel(item, selfId: selfId);
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 2,
        children: [
          if (dur.isNotEmpty) ...[Text(dur, style: style), dot],
          Text('added by ', style: style),
          StatusAvatar(info: _adderAvatar(item, members), size: fontSize + 3, badges: false, ring: false),
          const SizedBox(width: 4),
          Text(name, style: style),
          dot,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(howIcon(item.how), size: fontSize + 1, color: Colors.white38),
            const SizedBox(width: 3),
            Text(how, style: style),
          ]),
        ],
      );
    }
    return Row(
      children: [
        if (dur.isNotEmpty) ...[Text(dur, style: style), dot],
        Text('added by ', style: style),
        StatusAvatar(info: _adderAvatar(item, members), size: fontSize + 3, badges: false, ring: false),
        const SizedBox(width: 4),
        // Capped rather than flexible: two flexibles split the room in
        // half and would cut the end off even when it fits.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        dot,
        Icon(howIcon(item.how), size: fontSize + 1, color: Colors.white38),
        const SizedBox(width: 3),
        Flexible(
          child: Text(queueHowLabel(item, selfId: selfId), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
      ],
    );
  }
}

/// Every row of the popover (queued and continuation): one height, the
/// drag handle's width before the picture (a spacer where there is none),
/// one picture size and one type scale.
const queueRowHeight = 64.0;
const _lead = 22.0;
const _thumb = 80.0;
const _titleStyle = TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500);
const _subStyle = TextStyle(color: Colors.white60, fontSize: 12);

class _QueueRow extends StatefulWidget {
  final int index;
  final QueueItem item;
  final QueueController queue;
  final List<MemberView> members;
  final String selfId;
  /// The first item's readiness when this app puts it up; null: no dot.
  final WarmState? warm;
  /// Right-click ([context]: the row).
  final void Function(BuildContext context, QueueItem item) onMenu;
  const _QueueRow({
    super.key,
    required this.index,
    required this.item,
    required this.queue,
    required this.members,
    required this.selfId,
    required this.warm,
    required this.onMenu,
  });

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final row = AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: queueRowHeight,
        padding: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: _hover ? AppMenuStyle.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: widget.index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SizedBox(
                  width: _lead,
                  height: queueRowHeight,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _hover ? 0.8 : 0.25,
                    child: const Icon(Icons.drag_indicator_rounded, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ),
            // Its readiness rides on the picture's corner.
            Stack(
              children: [
                QueueThumb(queue: widget.queue, item: item, width: _thumb),
                if (widget.warm != null) Positioned(top: 3, right: 3, child: _WarmDot(state: widget.warm!)),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
                  if (item.sub.isNotEmpty)
                    Text(item.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: _subStyle),
                  const SizedBox(height: 2),
                  _MetaLine(item: item, members: widget.members, selfId: widget.selfId),
                ],
              ),
            ),
          ],
        ),
      );
    final actions = Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _hover ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_hover,
          child: Container(
            padding: const EdgeInsets.only(left: 28, right: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
              gradient: const LinearGradient(
                colors: [Color(0x00222226), Color(0xF0222226), Color(0xF0222226)],
                stops: [0, 0.3, 1],
              ),
            ),
            child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RoundIcon(
                      key: ValueKey('queue-play-${item.id}'),
                      icon: Icons.play_arrow_rounded,
                      tooltip: 'Play now',
                      onPressed: () => widget.queue.playNow(item.id),
                    ),
                    _RoundIcon(
                      key: ValueKey('queue-remove-${item.id}'),
                      icon: Icons.close_rounded,
                      size: 18,
                      color: Colors.white70,
                      tooltip: 'Remove',
                      onPressed: () => widget.queue.remove(item.id),
                    ),
                  ],
                ),
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTap: () => widget.onMenu(context, item),
        child: Stack(children: [row, actions]),
      ),
    );
  }
}

/// Hollow: not ready yet; pulsing: getting ready; filled: ready (red:
/// the link would not open).
class _WarmDot extends StatefulWidget {
  final WarmState state;
  const _WarmDot({required this.state});

  @override
  State<_WarmDot> createState() => _WarmDotState();
}

class _WarmDotState extends State<_WarmDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_WarmDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.state == WarmState.warming) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final green = Colors.greenAccent.shade400;
    final (color, filled, tip) = switch (widget.state) {
      WarmState.idle => (Colors.white54, false, 'Waiting to get ready'),
      WarmState.warming => (green, true, 'Getting it ready…'),
      WarmState.ready => (green, true, 'Ready to start'),
      WarmState.failed => (Colors.redAccent, true, "Couldn't get it ready; trying again shortly"),
    };
    return Tooltip(
      message: tip,
      // On a dark disc: it sits on the picture's corner.
      child: Container(
        key: const ValueKey('queue-warm-dot'),
        width: 14,
        height: 14,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xB3000000)),
        child: FadeTransition(
          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? color : Colors.transparent,
              border: Border.all(color: color, width: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinuationRow extends StatefulWidget {
  final EpisodeLink episode;
  final QueueController queue;
  const _ContinuationRow({required this.episode, required this.queue});

  @override
  State<_ContinuationRow> createState() => _ContinuationRowState();
}

class _ContinuationRowState extends State<_ContinuationRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final runtime = e.pick.runtime;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _hover ? 0.9 : 0.55,
        child: Container(
          height: queueRowHeight,
          padding: const EdgeInsets.only(left: _lead, right: 8),
          decoration: BoxDecoration(
            color: _hover ? AppMenuStyle.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
          ),
          child: Row(
            children: [
              _EpisodeThumb(queue: widget.queue, episode: e, width: _thumb),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
                    Text(
                      [if (runtime != null) queueClock(runtime.inSeconds.toDouble()), e.item.seriesName ?? '']
                          .where((s) => s.isNotEmpty)
                          .join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _subStyle,
                    ),
                  ],
                ),
              ),
              _RoundIcon(
                icon: Icons.add_rounded,
                size: 18,
                tooltip: 'Add to Up next',
                onPressed: () => widget.queue.promote(e),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- end card

/// When the media ended with Up next waiting: its picture, title and who
/// added it, the countdown with Cancel, and Play now.
class UpNextCard extends StatelessWidget {
  final QueueController queue;
  final UpNextCountdown countdown;
  const UpNextCard({super.key, required this.queue, required this.countdown});

  @override
  Widget build(BuildContext context) {
    final c = countdown;
    final item = c.item;
    final left = c.secondsLeft;
    final r = queue.coord.serverState.value;
    final selfId = queue.coord.sync.memberId;
    final waiting = left == null ? performerNote(queue, item, r) : null;
    return AppGlass(
      key: const ValueKey('up-next-card'),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  QueueThumb(queue: queue, item: item, width: 132),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(left == null ? 'Up next' : 'Up next in $left s',
                            style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.25)),
                        if (item.sub.isNotEmpty)
                          Text(item.sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        const SizedBox(height: 4),
                        _MetaLine(
                            item: item, members: r?.members ?? const [], selfId: selfId, fontSize: 11, wrap: true),
                      ],
                    ),
                  ),
                ],
              ),
              if (left != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: left / autoAdvanceSecs),
                    duration: const Duration(seconds: 1),
                    builder: (context, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 3,
                      backgroundColor: const Color(0x1FFFFFFF),
                    ),
                  ),
                ),
              ],
              if (waiting != null) ...[
                const SizedBox(height: 8),
                Text(waiting, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (left != null)
                    TextButton(
                        key: const ValueKey('up-next-cancel'),
                        onPressed: queue.cancelCountdown,
                        child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('up-next-play-now'),
                    onPressed: () => queue.playNow(item.id),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Play now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
