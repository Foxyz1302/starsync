import 'package:flutter/material.dart';

/// Product name (working title). Change it here only.
const appName = 'Watch Together';

const repoUrl = 'https://git.example.org/Foxyz/sync_replay_project';

const kRadius = 12.0;
const kGap = 16.0;
const kPagePadding = EdgeInsets.fromLTRB(28, 20, 28, 28);

/// Rounded panel used by every Home/Settings section.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool enabled;
  const Panel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(20),
      this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Material (not a DecoratedBox) so ink from tiles/chips inside shows.
    final panel = Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
    if (enabled) return panel;
    return Opacity(opacity: 0.5, child: IgnorePointer(child: panel));
  }
}

/// Page heading + optional subtitle, same spacing everywhere.
class PageTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const PageTitle(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: kGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.headlineSmall),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle!,
                  style: t.bodyMedium?.copyWith(color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}

/// Small grey heading inside a panel.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Text field style shared by the connect cards.
InputDecoration fieldDecoration(String label, {String? hint, Widget? suffix}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      suffixIcon: suffix,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    );

/// Single-item scrollable page body, width-capped so it doesn't sprawl
/// on wide windows.
class PageScroll extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;
  const PageScroll({super.key, required this.children, this.maxWidth = 920});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: kPagePadding,
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}
