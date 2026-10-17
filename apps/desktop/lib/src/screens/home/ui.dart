import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show appVersion, isDevBuild;

/// Product name (working title). Change it here only.
const appName = 'Starsync';

const repoUrl = 'https://git.example.org/Foxyz/sync_replay_project';

/// The pubspec's version: the Flutter tool defines it for every build and
/// run (`flutter run` too).
const _pubspecVersion = String.fromEnvironment('FLUTTER_BUILD_NAME');

/// The short commit a packaged build was made from (`tool/package_linux.sh`;
/// `-dirty` with uncommitted changes); empty otherwise.
const _gitCommit = String.fromEnvironment('GIT_COMMIT');

/// The version to show: a release's own ("1.1.2"), a test build's with its
/// commit ("1.1.3-dev.12 · 1a2b3c4"), and for a dev run (no `APP_VERSION`)
/// the pubspec's with "dev" ("1.1.2 · dev run").
String displayVersion({String version = appVersion, String pubspec = _pubspecVersion, String commit = _gitCommit}) {
  if (version == '0.0.0-dev') return pubspec.isEmpty ? 'dev run' : '$pubspec · dev run';
  return isDevBuild(version) && commit.isNotEmpty ? '$version · $commit' : version;
}

/// The version in a few characters, always on screen (under the strip's
/// Settings tab): "1.2.1", "1.2.1-dev.2", "dev run".
String shortVersion({String version = appVersion}) => version == '0.0.0-dev' ? 'dev run' : version;

/// Dev tools (Settings → About → Developer, the experiments they switch
/// on) only in test builds and runs from source (a `-dev` version) and
/// debug runs, never in a release.
bool devToolsFor({String version = appVersion, bool debug = kDebugMode}) => debug || version.contains('-dev');

/// [devToolsFor] this build.
final bool devTools = devToolsFor();

const kRadius = 12.0;
const kGap = 16.0;

/// Rounded panel used by every Settings section.
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

/// Outlined text field style (settings, Jellyfin sign-in).
InputDecoration fieldDecoration(String label, {String? hint, Widget? suffix}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      suffixIcon: suffix,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    );

/// Widest a single text field gets, however wide the window.
const kFieldMaxWidth = 720.0;

/// Inline failure under a connect form: bold title, selectable message.
class ErrorBox extends StatelessWidget {
  final String title;
  final String message;
  const ErrorBox({super.key, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$title\n',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: message),
              ]),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
