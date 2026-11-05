import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controls/frame.dart';
import '../shell/motion.dart';

// The app's one menu: a frosted dark panel anchored under (or over) the
// widget that opens it, rows with a hover and keyboard highlight, a check
// on the current one. [AppSelect] is the value picker built on it (in place
// of a dropdown), [AppMenuButton] the "⋮" action menu. The menu is a popup
// route: a click outside or Esc closes it, arrows and Enter pick, and the
// player's keys stay off while it is open (in fullscreen too).

/// The menu surface, shared with Material's own menus via [appMenuTheme].
abstract final class AppMenuStyle {
  /// Over a blur ([showAppMenu]).
  static const glass = Color(0xD918181C);
  /// Without a blur (Material menus).
  static const solid = Color(0xF518181C);
  static const border = Color(0x1FFFFFFF);
  static const hover = Color(0x14FFFFFF);
  static const focus = Color(0x24FFFFFF);
  /// The player's pills over the picture: lighter, so less of it is hidden.
  static const pillGlass = Color(0x8C000000);
  static const blur = 16.0;
  static const radius = 12.0;
  static const rowRadius = 8.0;
  static const rowHeight = 36.0;
  static const maxWidth = 360.0;

  static final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius),
    side: const BorderSide(color: border, width: 0.5),
  );

  /// The same surface for `showMenu`, `PopupMenuButton` and `MenuAnchor`.
  static ThemeData theme(ThemeData base) => base.copyWith(
        popupMenuTheme: PopupMenuThemeData(
          color: solid,
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shape: shape,
          menuPadding: const EdgeInsets.all(4),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: const WidgetStatePropertyAll(solid),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(8),
            shape: WidgetStatePropertyAll(shape),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          ),
        ),
      );
}

/// The app's one frosted surface: a blur under a dark tint, a hairline
/// border and (cards, menus) a soft shadow. Menus, popovers and the
/// player's cards use it as is; the player's pills with [pill].
class AppGlass extends StatelessWidget {
  final Widget child;
  final double radius;
  final Color color;
  final bool shadow;
  const AppGlass({
    super.key,
    required this.child,
    this.radius = AppMenuStyle.radius,
    this.color = AppMenuStyle.glass,
    this.shadow = true,
  });

  /// A stadium over the picture: the lighter tint, no shadow.
  const AppGlass.pill({super.key, required this.child})
      : radius = 999,
        color = AppMenuStyle.pillGlass,
        shadow = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final glass = ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: AppMenuStyle.blur, sigmaY: AppMenuStyle.blur),
        child: Material(
          color: color,
          shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: AppMenuStyle.border, width: 0.5)),
          child: child,
        ),
      ),
    );
    if (!shadow) return glass;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: glass,
    );
  }
}

/// One row: [label], a dim [hint] at the right, [checked] = the current
/// one (null: the menu has no checks for this row), [icon] before the
/// label (an action's own icon, the same as its button's).
class AppMenuItem<T> {
  final T value;
  final String label;
  final String? hint;
  final bool? checked;
  final IconData? icon;
  final bool enabled;
  final Key? key;
  const AppMenuItem({
    required this.value,
    required this.label,
    this.hint,
    this.checked,
    this.icon,
    this.enabled = true,
    this.key,
  });
}

/// The rows have a leading column: checks or icons.
bool _leads(List<AppMenuItem<Object?>> items) => items.any((i) => i.checked != null || i.icon != null);

/// Opens the menu at [context]'s box (the button). Resolves to the picked
/// value, or null when dismissed. [minWidth]: at least this wide (a picker
/// is as wide as its button).
///
/// [textAt]: where the button's own label starts inside it; the menu then
/// sits so its rows' text lines up with that label (a picker), else it
/// lines up with the button's left edge.
Future<T?> showAppMenu<T>(
  BuildContext context, {
  required List<AppMenuItem<T>> items,
  double minWidth = 0,
  double? textAt,
}) async {
  final i = await _openMenu(context, items, minWidth, textAt);
  return i == null ? null : items[i].value;
}

/// The picked row's index (the value may itself be null).
Future<int?> _openMenu(BuildContext context, List<AppMenuItem<Object?>> items, double minWidth, [double? textAt]) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  final box = context.findRenderObject() as RenderBox;
  final anchor = Rect.fromPoints(
    box.localToGlobal(Offset.zero, ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  // Lines the rows' text up with the button's label: panel padding (4)
  // plus the row's text inset, against [textAt].
  final shift = textAt == null ? 0.0 : textAt - 4 - _MenuRow.textInset(_leads(items));
  Future<int?> open() => navigator.push<int>(_AppMenuRoute(
        anchor: anchor.translate(shift, 0),
        items: items,
        minWidth: minWidth - shift,
        capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
      ));
  // Over the player's controls: keep them up while the menu is open.
  return ControlsFrame.holdWhile(context, open);
}

class _AppMenuRoute extends PopupRoute<int> {
  final Rect anchor;
  final List<AppMenuItem<Object?>> items;
  final double minWidth;
  final CapturedThemes capturedThemes;
  _AppMenuRoute({required this.anchor, required this.items, required this.minWidth, required this.capturedThemes});

  static const _gap = 4.0;
  static const _margin = 8.0;

  // Opens down unless the room below is short and above is roomier.
  bool _below(Size screen) {
    final want = items.length * AppMenuStyle.rowHeight + 8;
    final below = screen.height - anchor.bottom - _gap - _margin;
    final above = anchor.top - _gap - _margin;
    return below >= want || below >= above;
  }

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return LayoutBuilder(builder: (context, constraints) {
      final below = _below(constraints.biggest);
      final a = CurvedAnimation(parent: animation, curve: ease, reverseCurve: Curves.easeIn);
      return CustomSingleChildLayout(
        delegate: _MenuLayout(anchor: anchor, below: below, minWidth: minWidth),
        child: FadeTransition(
          opacity: a,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(a),
            alignment: below ? Alignment.topCenter : Alignment.bottomCenter,
            child: capturedThemes.wrap(_AppMenuPanel(
              items: items,
              onPick: (i) => Navigator.of(context).pop(i),
            )),
          ),
        ),
      );
    });
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool below;
  final double minWidth;
  const _MenuLayout({required this.anchor, required this.below, required this.minWidth});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    const m = _AppMenuRoute._margin, gap = _AppMenuRoute._gap;
    final maxW = math.max(0.0, math.min(math.max(AppMenuStyle.maxWidth, minWidth), constraints.maxWidth - 2 * m));
    final maxH = below ? constraints.maxHeight - anchor.bottom - gap - m : anchor.top - gap - m;
    return BoxConstraints(
      minWidth: math.min(minWidth, maxW),
      maxWidth: maxW,
      maxHeight: math.max(AppMenuStyle.rowHeight + 8, maxH),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const m = _AppMenuRoute._margin, gap = _AppMenuRoute._gap;
    final x = anchor.left.clamp(m, math.max(m, size.width - childSize.width - m)).toDouble();
    final y = below ? anchor.bottom + gap : anchor.top - gap - childSize.height;
    return Offset(x, y.clamp(m, math.max(m, size.height - childSize.height - m)).toDouble());
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor || old.below != below || old.minWidth != minWidth;
}

class _AppMenuPanel extends StatefulWidget {
  final List<AppMenuItem<Object?>> items;
  final ValueChanged<int> onPick;
  const _AppMenuPanel({required this.items, required this.onPick});

  @override
  State<_AppMenuPanel> createState() => _AppMenuPanelState();
}

class _AppMenuPanelState extends State<_AppMenuPanel> {
  final _current = GlobalKey();
  bool _keys = false;

  // Focus (and scroll to) the current row, else the first enabled one.
  late final int _start = () {
    final checked = widget.items.indexWhere((i) => i.checked == true && i.enabled);
    return checked >= 0 ? checked : widget.items.indexWhere((i) => i.enabled);
  }();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _current.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final checks = _leads(widget.items);
    final panel = AppGlass(
      key: const ValueKey('app-menu'),
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, item) in widget.items.indexed)
                _MenuRow(
                  key: i == _start ? _current : null,
                  item: item,
                  checks: checks,
                  autofocus: i == _start,
                  showFocus: _keys,
                  onTap: () => widget.onPick(i),
                ),
            ],
          ),
        ),
      ),
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        if (!_keys && e is KeyDownEvent) setState(() => _keys = true);
        return KeyEventResult.ignored;
      },
      child: panel,
    );
  }
}

class _MenuRow extends StatelessWidget {
  final AppMenuItem<Object?> item;
  /// The leading column (checks or icons).
  final bool checks;
  final bool autofocus;
  // Keyboard in use: the focused row shows (else focus stays invisible,
  // so the current row doesn't look hovered when the menu opens).
  final bool showFocus;
  final VoidCallback onTap;
  const _MenuRow(
      {super.key,
      required this.item,
      required this.checks,
      required this.autofocus,
      required this.showFocus,
      required this.onTap});

  /// Where a row's text starts, from the row's left edge.
  static double textInset(bool checks) => checks ? 8 + 22 : 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = item.checked == true;
    final color = item.enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);
    return InkWell(
      key: item.key,
      autofocus: autofocus,
      onTap: item.enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
      hoverColor: AppMenuStyle.hover,
      focusColor: showFocus ? AppMenuStyle.focus : Colors.transparent,
      highlightColor: AppMenuStyle.focus,
      splashFactory: NoSplash.splashFactory,
      child: Container(
        height: AppMenuStyle.rowHeight,
        padding: EdgeInsets.only(left: checks ? 8 : 12, right: 16),
        child: Row(
          children: [
            if (checks)
              SizedBox(
                width: 22,
                child: on
                    ? Icon(Icons.check_rounded, size: 16, color: scheme.primary)
                    : item.icon == null
                        ? null
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Icon(item.icon, size: 16, color: item.enabled ? scheme.onSurfaceVariant : color),
                          ),
              ),
            Flexible(
              fit: FlexFit.tight,
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: color),
              ),
            ),
            if (item.hint != null) ...[
              const SizedBox(width: 16),
              Text(item.hint!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// A value picker (in place of a dropdown): the current label and a small
/// chevron on a soft rounded surface; the menu lists [items] (value,
/// label) with the current one checked. [onChanged] null: disabled.
/// [expanded]: fills the width it gets (the label ellipsizes).
class AppSelect<T> extends StatefulWidget {
  /// Where the label starts inside the button (its left padding); the
  /// menu's text lines up with it.
  static const labelInset = 10.0;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T>? onChanged;
  final bool expanded;
  final TextStyle? style;
  const AppSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expanded = false,
    this.style,
  });

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  bool _open = false;

  Future<void> _show(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    setState(() => _open = true);
    final items = [
      for (final (v, label) in widget.items) AppMenuItem<T>(value: v, label: label, checked: v == widget.value),
    ];
    final i = await _openMenu(context, items, box.size.width, AppSelect.labelInset);
    if (!mounted) return;
    setState(() => _open = false);
    if (i != null) widget.onChanged?.call(widget.items[i].$1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final label = widget.items.where((e) => e.$1 == widget.value).firstOrNull?.$2 ?? '';
    final base = Theme.of(context).textTheme.bodyMedium!.merge(widget.style);
    final style = enabled ? base : base.copyWith(color: base.color?.withValues(alpha: 0.38));
    final r = BorderRadius.circular(AppMenuStyle.rowRadius);
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    return Semantics(
      button: true,
      value: label,
      child: Builder(
        builder: (context) => Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? () => _show(context) : null,
            borderRadius: r,
            hoverColor: AppMenuStyle.hover,
            focusColor: AppMenuStyle.focus,
            highlightColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: ease,
              padding: const EdgeInsets.only(left: AppSelect.labelInset, right: 6, top: 6, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: _open ? 0.10 : 0.05),
                borderRadius: r,
                border: Border.all(color: _open ? scheme.primary.withValues(alpha: 0.6) : AppMenuStyle.border, width: 0.5),
              ),
              child: Row(
                mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  if (widget.expanded) Expanded(child: text) else Flexible(child: text),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: easeTime,
                    curve: ease,
                    child: Icon(Icons.keyboard_arrow_down_rounded,
                        size: 18, color: enabled ? scheme.onSurfaceVariant : style.color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "⋮" (or [icon]) opening an action menu of [items]; [onSelected] gets
/// the picked value.
class AppMenuButton<T> extends StatelessWidget {
  final List<AppMenuItem<T>> Function() items;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final Widget icon;
  const AppMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.icon = const Icon(Icons.more_vert, size: 18),
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: () async {
        final list = items();
        if (list.isEmpty) return;
        final i = await _openMenu(context, list, 0);
        if (i != null) onSelected(list[i].value);
      },
    );
  }
}
