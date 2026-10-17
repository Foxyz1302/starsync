import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName;
import '../shell/motion.dart';
import '../update/whats_new.dart';
import 'app_menu.dart';

// The "What's new" card: a version's changes (CHANGELOG.md, through the
// manifest's `changes`) as Added / Changed / Fixed sections, each with its
// icon and colour, on the app's glass. The update band opens it for the
// offered version, the first start after an update for the new one
// ([WhatsNew]), Settings → About for the running one. Notes without
// `changes` (older manifests) show as one paragraph.

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

  int get _rows => widget.notes.changes?.length ?? 1;

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
    final changes = n.changes;
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = math.min(620.0, screen.height - 64);
    var row = 0;
    final body = <Widget>[
      if (changes == null)
        _staggered(row++, Text(n.notes, style: const TextStyle(fontSize: 13.5, height: 1.45)))
      else
        for (final k in ChangeKind.values)
          if (k.of(changes).isNotEmpty) ...[
            _staggered(row++, _SectionHead(kind: k, count: k.of(changes).length)),
            const SizedBox(height: 6),
            for (final item in k.of(changes)) _staggered(row++, _Item(kind: k, text: item)),
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
            if (changes != null && n.notes.trim().isNotEmpty)
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
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
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
  final ChangeKind kind;
  final String text;
  const _Item({required this.kind, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 2),
          child: DecoratedBox(
            decoration: BoxDecoration(color: kind.color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: SizedBox.square(
              dimension: 16,
              child: Icon(
                kind.bullet,
                size: 12,
                color: kind.color,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4))),
      ],
    ),
  );
}

/// The band's line: the first items with their kind's icon, in [color].
class WhatsNewPreview extends StatelessWidget {
  final ReleaseChanges changes;
  final Color color;
  final String? lead;
  const WhatsNewPreview({super.key, required this.changes, required this.color, this.lead});

  @override
  Widget build(BuildContext context) {
    final top = topChanges(changes, 3);
    final style = TextStyle(color: color.withValues(alpha: 0.85), fontSize: 12);
    return Text.rich(
      key: const ValueKey('whats-new-preview'),
      TextSpan(
        children: [
          if (lead != null) TextSpan(text: '$lead  ·  '),
          for (final (i, (k, item)) in top.indexed) ...[
            if (i > 0) const TextSpan(text: '   '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(k.icon, size: 13, color: color.withValues(alpha: 0.85)),
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
