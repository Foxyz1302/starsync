import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName;
import '../shell/motion.dart';
import '../update/whats_new.dart';
import 'app_menu.dart';

// The "What's new" card: a version's highlights (CHANGELOG.md's
// `### Highlights`, the manifest's `highlights`), then "All changes"
// unfolds its full Added / Changed / Fixed sections (`changes`), each with
// its icon and colour, on the app's glass. A version without highlights
// shows its first items instead. The update band opens it for the offered
// version, the first start after an update for the new one ([WhatsNew]),
// Settings → About for the running one. Notes without `changes` (older
// manifests) show as one paragraph.

enum ChangeKind {
  added('Added', Icons.auto_awesome_rounded, Icons.add_rounded, Color(0xFF7EE0A6)),
  changed('Changed', Icons.tune_rounded, Icons.arrow_forward_rounded, Color(0xFF8DB8FF)),
  fixed('Fixed', Icons.handyman_rounded, Icons.check_rounded, Color(0xFFFFC772));

  final String label;
  final IconData icon;
  /// Before each item.
  final IconData bullet;

  /// Reads on the dark glass.
  final Color color;
  const ChangeKind(this.label, this.icon, this.bullet, this.color);

  List<String> of(ReleaseChanges c) => switch (this) {
    ChangeKind.added => c.added,
    ChangeKind.changed => c.changed,
    ChangeKind.fixed => c.fixed,
  };
}

/// The first [n] items, Added before Changed before Fixed.
List<(ChangeKind, String)> topChanges(ReleaseChanges c, int n) => [
  for (final k in ChangeKind.values)
    for (final item in k.of(c)) (k, item),
].take(n).toList();

/// How many items a version without highlights shows before "All changes".
const whatsNewFirstItems = 4;

/// A highlight's bullet and colour (a soft lilac that reads on the glass).
const _highlightBullet = Icons.star_rounded;
const _highlightColor = Color(0xFFD2B6FF);

/// Opens the card over the window. [action]: a button beside Close (the
/// band's "Update and restart").
Future<void> showWhatsNew(BuildContext context, ReleaseNotes notes, {String? overline, Widget? action}) =>
    showPopover<void>(
      context,
      at: Alignment.center,
      dim: true,
      child: WhatsNewCard(notes: notes, overline: overline, action: action),
    );

class WhatsNewCard extends StatefulWidget {
  final ReleaseNotes notes;

  /// The small line over the title (default: the app's name).
  final String? overline;
  final Widget? action;

  /// Default: closes the route.
  final VoidCallback? onClose;
  const WhatsNewCard({super.key, required this.notes, this.overline, this.action, this.onClose});

  @override
  State<WhatsNewCard> createState() => _WhatsNewCardState();
}

class _WhatsNewCardState extends State<WhatsNewCard> with SingleTickerProviderStateMixin {
  late final _intro = AnimationController(
    vsync: this,
    duration: easeTime + Duration(milliseconds: 45 * math.min(_rows, 12)),
  )..forward();

  /// "All changes" was clicked: the full lists show under the highlights.
  bool _all = false;

  ReleaseChanges? get _changes => widget.notes.changes;
  List<String> get _highlights => widget.notes.highlights;

  /// The full lists wait behind "All changes": there are highlights, or
  /// more items than the first few.
  bool get _folded => _changes != null && (_highlights.isNotEmpty || _changes!.length > whatsNewFirstItems);

  int get _rows => _highlights.isNotEmpty
      ? _highlights.length
      : _folded
      ? whatsNewFirstItems
      : _changes?.length ?? 1;

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  /// Row [i] of [_rows] slides up and fades in a little after the one above.
  Widget _staggered(int i, Widget child) {
    final start = math.min(i, 12) * 0.06;
    final a = CurvedAnimation(
      parent: _intro,
      curve: Interval(math.min(start, 0.6), 1, curve: ease),
    );
    return FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
        child: child,
      ),
    );
  }

  void _close() => widget.onClose != null ? widget.onClose!() : Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const muted = Color(0xB3FFFFFF);
    final n = widget.notes;
    final changes = _changes;
    final highlights = _highlights;
    final folded = _folded && !_all;
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = math.min(620.0, screen.height - 64);
    var row = 0;
    final body = <Widget>[
      for (final item in highlights)
        _staggered(row++, _Item(bullet: _highlightBullet, color: _highlightColor, text: item, strong: true)),
      if (highlights.isNotEmpty) const SizedBox(height: 10),
      if (changes == null) ...[
        if (highlights.isEmpty) _staggered(row++, Text(n.notes, style: const TextStyle(fontSize: 13.5, height: 1.45))),
      ] else if (folded) ...[
        if (highlights.isEmpty)
          for (final (k, item) in topChanges(changes, whatsNewFirstItems))
            _staggered(row++, _Item(bullet: k.bullet, color: k.color, text: item)),
        _staggered(
          row++,
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('whats-new-all'),
              style: TextButton.styleFrom(
                foregroundColor: muted,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 10, 0),
              ),
              onPressed: () => setState(() => _all = true),
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              label: Text('All changes (${changes.length})'),
            ),
          ),
        ),
        const SizedBox(height: 6),
      ] else
        for (final k in ChangeKind.values)
          if (k.of(changes).isNotEmpty) ...[
            _staggered(row++, _SectionHead(kind: k, count: k.of(changes).length)),
            const SizedBox(height: 6),
            for (final item in k.of(changes)) _staggered(row++, _Item(bullet: k.bullet, color: k.color, text: item)),
            const SizedBox(height: 10),
          ],
    ];
    return AppGlass(
      key: const ValueKey('whats-new-card'),
      radius: 16,
      child: ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: math.min(460.0, screen.width - 32)).copyWith(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [scheme.primary, scheme.tertiary.withValues(alpha: 0.85)],
                      ),
                      boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 14)],
                    ),
                    child: const SizedBox.square(
                      dimension: 40,
                      child: Icon(Icons.auto_awesome, color: Colors.white, size: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (widget.overline ?? appName).toUpperCase(),
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "What's new in ${n.version}",
                          key: const ValueKey('whats-new-title'),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.2),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18, color: muted),
                    onPressed: _close,
                  ),
                ],
              ),
            ),
            // The summary, unless the highlights already say it.
            if (changes != null && highlights.isEmpty && n.notes.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                child: Text(n.notes, style: const TextStyle(color: muted, fontSize: 13, height: 1.4)),
              ),
            const SizedBox(height: 12),
            const Divider(height: 1, thickness: 0.5, color: AppMenuStyle.border),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('whats-new-list'),
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: AnimatedSize(
                  duration: easeTime,
                  curve: ease,
                  alignment: Alignment.topCenter,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
                ),
              ),
            ),
            const Divider(height: 1, thickness: 0.5, color: AppMenuStyle.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.action != null) ...[
                    TextButton(key: const ValueKey('whats-new-close'), onPressed: _close, child: const Text('Close')),
                    const SizedBox(width: 8),
                    widget.action!,
                  ] else
                    FilledButton.tonal(
                      key: const ValueKey('whats-new-close'),
                      onPressed: _close,
                      child: const Text('Nice'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  final ChangeKind kind;
  final int count;
  const _SectionHead({required this.kind, required this.count});

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: DecoratedBox(
      key: ValueKey('whats-new-${kind.name}'),
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kind.color.withValues(alpha: 0.28), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kind.icon, size: 14, color: kind.color),
            const SizedBox(width: 6),
            Text(
              kind.label,
              style: TextStyle(color: kind.color, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            ),
            const SizedBox(width: 6),
            Text('$count', style: TextStyle(color: kind.color.withValues(alpha: 0.7), fontSize: 11.5)),
          ],
        ),
      ),
    ),
  );
}

class _Item extends StatelessWidget {
  final IconData bullet;
  final Color color;
  final String text;

  /// A highlight: a touch brighter than a list item.
  final bool strong;
  const _Item({required this.bullet, required this.color, required this.text, this.strong = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 2),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: SizedBox.square(
              dimension: 16,
              child: Icon(
                bullet,
                size: 12,
                color: color,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: strong ? 14 : 13.5, height: 1.4, fontWeight: strong ? FontWeight.w500 : null),
          ),
        ),
      ],
    ),
  );
}

/// The band's line: the first highlights (or, without them, the first
/// items with their kind's icon), in [color].
class WhatsNewPreview extends StatelessWidget {
  final ReleaseNotes notes;
  final Color color;
  final String? lead;
  const WhatsNewPreview({super.key, required this.notes, required this.color, this.lead});

  @override
  Widget build(BuildContext context) {
    final top = notes.highlights.isNotEmpty
        ? [for (final h in notes.highlights.take(3)) (Icons.auto_awesome_rounded, h)]
        : [for (final (k, item) in topChanges(notes.changes ?? const ReleaseChanges(), 3)) (k.icon, item)];
    final style = TextStyle(color: color.withValues(alpha: 0.85), fontSize: 12);
    return Text.rich(
      key: const ValueKey('whats-new-preview'),
      TextSpan(
        children: [
          if (lead != null) TextSpan(text: '$lead  ·  '),
          for (final (i, (icon, item)) in top.indexed) ...[
            if (i > 0) const TextSpan(text: '   '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
              ),
            ),
            TextSpan(text: item),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
