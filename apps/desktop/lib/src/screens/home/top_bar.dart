import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../update/update_controller.dart';
import '../../widgets/window_buttons.dart';
import 'profile.dart';
import 'update_indicator.dart';

/// What the Home body shows: the two tabs, or one of the side pages.
enum HomeView { join, host, settings, integrations, about }

const homeTopBarHeight = 48.0;

/// Below this width the bar drops the profile name and tab icons.
const _compactBelow = 760.0;

/// Home's single top bar: profile, Join/Host tabs, update pill, page
/// buttons and (in the real window) the drag area and window buttons.
class HomeTopBar extends StatelessWidget {
  final HomeView view;
  final ValueChanged<HomeView> onSelect;
  final UpdateController? updates;
  /// Off in tests: the drag area and window buttons need window_manager.
  final bool windowControls;
  const HomeTopBar({
    super.key,
    required this.view,
    required this.onSelect,
    this.updates,
    this.windowControls = false,
  });

  static const _pages = [
    (HomeView.settings, Icons.settings_outlined, Icons.settings, 'Settings'),
    (HomeView.integrations, Icons.extension_outlined, Icons.extension, 'Integrations'),
    (HomeView.about, Icons.info_outline, Icons.info, 'About'),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
        builder: (context, box) => _bar(context, compact: box.maxWidth < _compactBelow));
  }

  Widget _bar(BuildContext context, {required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final row = Row(
      children: [
        const SizedBox(width: 12),
        ProfileChip(dense: true, avatarOnly: compact),
        SizedBox(width: compact ? 8 : 20),
        _Tab(
          key: const ValueKey('tab-join'),
          label: 'Join',
          icon: compact ? null : Icons.login,
          selected: view == HomeView.join,
          onTap: () => onSelect(HomeView.join),
        ),
        _Tab(
          key: const ValueKey('tab-host'),
          label: 'Host',
          icon: compact ? null : Icons.cast,
          selected: view == HomeView.host,
          onTap: () => onSelect(HomeView.host),
        ),
        const Spacer(),
        UpdateIndicator(controller: updates),
        const SizedBox(width: 8),
        for (final (v, icon, selectedIcon, label) in _pages)
          IconButton(
            tooltip: label,
            isSelected: view == v,
            icon: Icon(icon, size: 20),
            selectedIcon: Icon(selectedIcon, size: 20, color: scheme.primary),
            onPressed: () => onSelect(v),
          ),
        if (windowControls) ...[
          const SizedBox(width: 4),
          SizedBox(
            height: 20,
            child: VerticalDivider(width: 12, color: scheme.outlineVariant),
          ),
          const WindowButtons(),
        ] else
          const SizedBox(width: 8),
      ],
    );
    final bar = SizedBox(height: homeTopBarHeight, child: row);
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      // Empty bar space drags the window; the controls on top take their
      // own clicks without waiting out the drag area's double-tap.
      child: windowControls
          ? Stack(children: [
              const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
              bar,
            ])
          : bar,
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  const _Tab(
      {super.key,
      required this.label,
      this.icon,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: homeTopBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
              ],
              Text(label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: color, fontWeight: selected ? FontWeight.w600 : null)),
            ],
          ),
        ),
      ),
    );
  }
}

