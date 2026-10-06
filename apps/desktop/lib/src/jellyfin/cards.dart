import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'format.dart';
import 'images.dart';

enum CardShape {
  /// 2:3 poster (movies, series, latest).
  poster(2 / 3, 150),
  /// 16:9 thumbnail (continue watching, next up, episodes).
  thumb(16 / 9, 260);

  /// Image width / height.
  final double aspect;
  /// Smallest card width; rows and grids add columns past it.
  final double minWidth;
  const CardShape(this.aspect, this.minWidth);
}

/// Title + subtitle lines under a card image.
const cardTextHeight = 46.0;
const cardGap = 12.0;

/// Card image for [item] in [shape]: thumbs prefer the item's own
/// screenshot / thumb / backdrop, posters the primary (series poster for
/// episodes).
JellyfinImageRef? cardImage(JellyfinItem item, CardShape shape) {
  if (shape == CardShape.poster) return item.image(JellyfinImageType.primary);
  final own = item.ownImage(JellyfinImageType.primary);
  final primaryIsWide = (item.primaryImageAspectRatio ?? 0) > 1.2 ||
      item.kind == JellyfinItemKind.episode ||
      item.kind == JellyfinItemKind.video;
  if (own != null && primaryIsWide) return own;
  return item.image(JellyfinImageType.thumb) ??
      item.image(JellyfinImageType.backdrop) ??
      item.image(JellyfinImageType.primary);
}

IconData kindIcon(JellyfinItem item) => switch (item.kind) {
      JellyfinItemKind.series || JellyfinItemKind.season => Icons.live_tv_outlined,
      JellyfinItemKind.episode => Icons.tv_outlined,
      JellyfinItemKind.folder || JellyfinItemKind.collectionFolder => Icons.folder_outlined,
      JellyfinItemKind.boxSet => Icons.collections_bookmark_outlined,
      _ => Icons.movie_outlined,
    };

/// Poster or thumb card: image with progress bar and state badges, title
/// and one meta line. Click / Enter activates (pick or open), hover and
/// focus feed the inspector, "i" or the hover button opens the details.
class MediaCard extends StatefulWidget {
  final JellyfinItem item;
  final CardShape shape;
  /// Rows mixing series (Continue watching, Next up): series name on top,
  /// "S2E3 · 12 min left" below.
  final bool seriesFirst;
  final bool autofocus;
  const MediaCard({
    super.key,
    required this.item,
    required this.shape,
    this.seriesFirst = false,
    this.autofocus = false,
  });

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hover = false;
  bool _focus = false;

  JellyfinItem get item => widget.item;

  void _details(BrowseScope scope) => scope.onOpen(DetailRoute(item));

  KeyEventResult _onKey(BrowseScope scope, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyI && isPlayable(item)) {
      _details(scope);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = scope.selectedItemId == item.id;
    final played = item.userData.played;
    final progress = progressOf(item);
    final unplayed = item.userData.unplayedItemCount;
    final ring = selected
        ? scheme.primary
        : _focus
            ? scheme.onSurface
            : Colors.transparent;

    final image = AspectRatio(
      aspectRatio: widget.shape.aspect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ring, width: 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              JellyfinImage(
                client: scope.client,
                image: cardImage(item, widget.shape),
                icon: kindIcon(item),
              ),
              if (_hover || _focus)
                const ColoredBox(color: Color(0x22FFFFFF)),
              if (progress > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Colors.black54,
                  ),
                ),
              Positioned(
                top: 6,
                right: 6,
                child: selected
                    ? _Badge(color: scheme.primary, child: Icon(Icons.check, size: 14, color: scheme.onPrimary))
                    : played
                        ? const _Badge(color: Color(0xCC1B5E20), child: Icon(Icons.check, size: 14, color: Colors.white))
                        : unplayed != null && unplayed > 0 && !isPlayable(item)
                            ? _Badge(
                                color: scheme.primaryContainer,
                                child: Text('$unplayed',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onPrimaryContainer)))
                            : const SizedBox.shrink(),
              ),
              if (_hover && isPlayable(item))
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton.filledTonal(
                    key: ValueKey('card-info-${item.id}'),
                    tooltip: 'Details (I)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => _details(scope),
                    icon: const Icon(Icons.info_outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final title = cardTitle(item, seriesFirst: widget.seriesFirst);
    final sub = widget.seriesFirst && item.kind == JellyfinItemKind.episode
        ? [cardSubtitle(item), item.name].where((s) => s.isNotEmpty).join(' · ')
        : cardSubtitle(item);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => _onKey(scope, e),
      child: Semantics(
        button: true,
        selected: selected,
        label: title,
        child: InkWell(
          key: ValueKey('card-${item.id}'),
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(8),
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: () => scope.activate(item),
          onHover: (h) {
            setState(() => _hover = h);
            if (h) scope.onPeek(item);
          },
          onFocusChange: (f) {
            setState(() => _focus = f);
            if (f) scope.onPeek(item);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              image,
              const SizedBox(height: 6),
              SizedBox(
                height: cardTextHeight - 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: selected ? scheme.primary : null)),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final Color color;
  final Widget child;
  const _Badge({required this.color, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(11)),
        child: child,
      );
}

/// Columns and card width that fill [width] exactly with cards at least
/// [minWidth] wide: no half-cut card at the edge, any window width.
({int cols, double itemWidth}) fitColumns(double width, double minWidth, {double gap = cardGap}) {
  final cols = math.max(1, ((width + gap) / (minWidth + gap)).floor());
  return (cols: cols, itemWidth: (width - gap * (cols - 1)) / cols);
}

/// Grid layout for cards: as many columns as fit, height = image + text.
class CardGridDelegate extends SliverGridDelegate {
  final CardShape shape;
  final double minWidth;
  CardGridDelegate(this.shape, {double? minWidth}) : minWidth = minWidth ?? shape.minWidth;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final fit = fitColumns(constraints.crossAxisExtent, minWidth);
    final h = fit.itemWidth / shape.aspect + cardTextHeight;
    return SliverGridRegularTileLayout(
      crossAxisCount: fit.cols,
      mainAxisStride: h + 18,
      crossAxisStride: fit.itemWidth + cardGap,
      childMainAxisExtent: h,
      childCrossAxisExtent: fit.itemWidth,
      reverseCrossAxis: false,
    );
  }

  @override
  bool shouldRelayout(CardGridDelegate old) => old.shape != shape || old.minWidth != minWidth;
}

/// A titled horizontal row of cards sized to fill the width; arrows (on
/// hover) page through it. Lazy: only visible cards are built.
class MediaRow extends StatefulWidget {
  final String title;
  final List<JellyfinItem> items;
  final CardShape shape;
  final bool seriesFirst;
  final Widget? trailing;
  const MediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.shape,
    this.seriesFirst = false,
    this.trailing,
  });

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _scroll = ScrollController();
  bool _hover = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _page(int dir, double width) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final to = (p.pixels + dir * (width + cardGap)).clamp(0.0, p.maxScrollExtent);
    _scroll.animateTo(to, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(widget.title, style: t.titleMedium),
                const SizedBox(width: 8),
                Text('${widget.items.length}', style: t.bodySmall?.copyWith(color: Colors.grey)),
                const Spacer(),
                ?widget.trailing,
              ],
            ),
          ),
          LayoutBuilder(builder: (context, box) {
            final fit = fitColumns(box.maxWidth, widget.shape.minWidth);
            final h = fit.itemWidth / widget.shape.aspect + cardTextHeight;
            final overflow = widget.items.length > fit.cols;
            return SizedBox(
              height: h,
              child: Stack(
                children: [
                  ListView.separated(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: cardGap),
                    itemBuilder: (context, i) => SizedBox(
                      width: fit.itemWidth,
                      child: MediaCard(
                        item: widget.items[i],
                        shape: widget.shape,
                        seriesFirst: widget.seriesFirst,
                      ),
                    ),
                  ),
                  if (overflow && _hover) ...[
                    _PageArrow(left: true, height: h - cardTextHeight, onTap: () => _page(-1, box.maxWidth)),
                    _PageArrow(left: false, height: h - cardTextHeight, onTap: () => _page(1, box.maxWidth)),
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _PageArrow extends StatelessWidget {
  final bool left;
  final double height;
  final VoidCallback onTap;
  const _PageArrow({required this.left, required this.height, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      height: height,
      child: Center(
        child: ExcludeFocus(
          child: IconButton.filledTonal(
            tooltip: left ? 'Previous' : 'Next',
            onPressed: onTap,
            icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
          ),
        ),
      ),
    );
  }
}

/// Section heading used above grids and rows.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? count;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.count, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Text(title, style: t.titleMedium),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(count!, style: t.bodySmall?.copyWith(color: Colors.grey)),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}
