import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show HelloMedia, JellyfinException, JellyfinItem;

import '../files/ui/files_page.dart';
import '../jellyfin/accounts.dart';
import '../jellyfin/browse_scope.dart';
import '../jellyfin/details_panel.dart';
import '../jellyfin/format.dart' show pickFor;
import '../jellyfin/home_page.dart' show libraryIcon, isVideoLibrary;
import '../jellyfin/picker_source.dart';
import '../jellyfin/session_media.dart';
import '../screens/home/media_picker.dart';
import '../session/app_events.dart' show ActionFailed;
import '../app/app_graph.dart';
import 'library_link.dart';
import 'motion.dart';
import 'welcome.dart';

/// What putting up a Jellyfin pick sends: its ref (no URL, no token).
/// Throws [FormatException] with a user-facing message when the server is
/// not linked any more or its sign-in expired.
HelloMedia putUpJellyfinMedia(JellyfinAccounts accounts, JellyfinMedia media) {
  if (accounts.account(media.serverId) == null) {
    throw const FormatException('that Jellyfin server is not linked any more — pick again');
  }
  if (accounts.statusOf(media.serverId) == JellyfinAccountStatus.expired) {
    throw const FormatException('Jellyfin sign-in expired — reconnect it in Settings → Library & accounts');
  }
  return mediaForPick(media);
}

/// Brings back the last Jellyfin pick (kept in the Jellyfin box) once the
/// accounts are read, unless something else was picked meanwhile or
/// [alive] says the picker is gone.
Future<void> restoreLastPick(
    MediaPickerController c, JellyfinAccounts accounts, bool Function() alive) async {
  final hadMedia = c.selection != null;
  try {
    await accounts.ensureLoaded();
  } catch (_) {
    return;
  }
  final pick = accounts.lastPick;
  if (!alive() || pick == null || c.jellyfin != null) return;
  if (accounts.account(pick.serverId) == null) return;
  final source = c.source;
  c.pickJellyfin(pick);
  if (hadMedia) c.source = source;
}

/// The file playing now, when it is the one put up from here last: the
/// server's current media (state JSON) is a plain file (no link, no
/// Jellyfin ref) named like [lastPath].
String? nowPlayingFile(Map<String, Object?>? media, String lastPath) {
  if (media == null || media['url'] != null || media['jellyfin'] != null || lastPath.isEmpty) return null;
  final name = lastPath.split(RegExp(r'[/\\]')).lastWhere((p) => p.isNotEmpty, orElse: () => lastPath);
  return name == media['name'] ? lastPath : null;
}

/// Window width under which the details panel floats over the library.
const detailsDockFrom = 1000.0;

/// The Library tab: a source switch (Jellyfin / Link / Files, fading
/// through), the Jellyfin library chips beside it, and the source below.
/// Jellyfin cards select on click and open their details in a panel at
/// the right (docked from [detailsDockFrom], floating over the library
/// below it); a double-click or the panel's button puts it up. With
/// nobody else in the server ([alone], D9) the buttons say Play.
class LibraryTab extends StatefulWidget {
  final MediaPickerController controller;
  final JellyfinAccounts accounts;
  final bool alone;
  /// This app hosts the server: its files stream from here directly.
  final bool isHost;
  final BrowseStart? jellyfinStart;
  /// Puts the pick up; returns an error text, or null when sent.
  final Future<String?> Function(PickedMedia media) onPutUp;
  /// Adds a pick to Up next; null without a server (no queue actions).
  final AddToQueue? onAddToQueue;
  final VoidCallback? onPutUpDone;
  final VoidCallback? onOpenAccounts;
  /// The Link page's Recent list (the shell's).
  final RecentLinks recentLinks;
  /// What a link is; defaults to the app's.
  final LinkProber? probe;
  /// The Files source (tests inject one); defaults to [FilesPage].
  final Widget Function(BuildContext context, {required bool alone, required bool relayed,
      required Future<String?> Function(String path) onPlay, String? nowPlayingPath})? filesBuilder;
  /// Clock for the Jellyfin Continue row (tests pin it).
  final DateTime Function() now;
  /// Over the source switch (the shell's welcome band while offline).
  final Widget? banner;
  const LibraryTab({
    super.key,
    required this.controller,
    required this.accounts,
    required this.alone,
    required this.isHost,
    required this.onPutUp,
    this.onAddToQueue,
    this.onPutUpDone,
    this.jellyfinStart,
    this.onOpenAccounts,
    required this.recentLinks,
    this.probe,
    this.filesBuilder,
    this.now = DateTime.now,
    this.banner,
  });

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late final BrowseController _browse = BrowseController(widget.accounts, now: widget.now);
  /// What the closing panel keeps showing while it slides out.
  JellyfinSelection? _shown;

  MediaPickerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _browse.addListener(_changed);
    _shown = _c.selected;
  }

  @override
  void didUpdateWidget(LibraryTab old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _browse.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (_c.selected != null) _shown = _c.selected;
    });
  }

  // ------------------------------------------------------------- put up

  Future<String?> _put(PickedMedia media) async {
    String? error;
    try {
      error = await widget.onPutUp(media);
    } catch (e) {
      error = '$e';
    }
    if (error == null) widget.onPutUpDone?.call();
    return error;
  }

  /// A Jellyfin card or episode: a series goes up as its next episode.
  Future<String?> _putUpJellyfin(JellyfinSelection sel) async {
    final pick = await _jellyfinPick(sel);
    return pick is JellyfinMedia ? _put(pick) : pick as String;
  }

  /// What a Jellyfin card stands for (a series: its next episode), or an
  /// error text.
  Future<Object> _jellyfinPick(JellyfinSelection sel) async {
    final account = widget.accounts.account(sel.serverId);
    final client = widget.accounts.clientFor(sel.serverId);
    if (account == null || client == null) return 'that Jellyfin server is not linked any more';
    JellyfinItem? item = sel.item;
    try {
      item ??= await client.item(sel.itemId);
      item = await playableFor(client, item);
    } on JellyfinException catch (e) {
      return e.message;
    }
    if (item == null) return 'nothing to play in there';
    return pickFor(account, item);
  }

  /// "Add to queue" on a Jellyfin card, episode or the details panel.
  Future<String?> _queueJellyfin(JellyfinSelection sel, {bool next = false}) async {
    final add = widget.onAddToQueue;
    if (add == null) return null;
    final pick = await _jellyfinPick(sel);
    return pick is JellyfinMedia ? add(pick, next: next) : pick as String;
  }

  /// A card's menu: errors as a toast (the Notifier's).
  Future<void> _cardQueue(JellyfinSelection sel, {bool next = false}) async {
    final error = await _queueJellyfin(sel, next: next);
    if (error != null && mounted) AppScope.of(context).notifier.notify(ActionFailed(error));
  }

  /// Double-click on a card: put it up, errors as a toast.
  Future<void> _doublePutUp(JellyfinSelection sel) async {
    _c.select(sel);
    final error = await _putUpJellyfin(sel);
    if (error != null && mounted) AppScope.of(context).notifier.notify(ActionFailed(error));
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final source = _c.source;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: LayoutBuilder(builder: (context, box) {
        // Narrow: icons only, so the chips keep some room.
        final labels = box.maxWidth >= 620;
        ButtonSegment<MediaKind> seg(MediaKind k, IconData icon, String label) => ButtonSegment(
            value: k, icon: Icon(icon), label: labels ? Text(label) : null, tooltip: labels ? null : label);
        return Row(
          children: [
            SegmentedButton<MediaKind>(
              key: const ValueKey('media-source'),
              showSelectedIcon: false,
              segments: [
                seg(MediaKind.jellyfin, Icons.video_library_outlined, 'Jellyfin'),
                seg(MediaKind.link, Icons.link, 'Link'),
                seg(MediaKind.file, Icons.folder_outlined, 'Files'),
              ],
              selected: {source},
              onSelectionChanged: (s) => _c.source = s.first,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: easeTime,
                child: source == MediaKind.jellyfin
                    ? _LibraryChips(key: const ValueKey('chips'), controller: _browse)
                    : const SizedBox(height: 40),
              ),
            ),
          ],
        );
      }),
    );

    final Widget content = switch (source) {
      MediaKind.jellyfin => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: JellyfinPickerSource(
            accounts: widget.accounts,
            controller: _browse,
            selected: _c.selected,
            onSelect: _c.select,
            onPutUp: _doublePutUp,
            onAddToQueue: widget.onAddToQueue == null ? null : _cardQueue,
            onOpenAccounts: widget.onOpenAccounts,
            start: widget.jellyfinStart,
            libraryStrip: false,
            empty: (context) => NoJellyfinPanel(
              accounts: widget.accounts,
              onFiles: () => _c.source = MediaKind.file,
              onLink: () => _c.source = MediaKind.link,
            ),
          ),
        ),
      MediaKind.link => LibraryLinkSource(
          controller: _c,
          alone: widget.alone,
          recents: widget.recentLinks,
          probe: widget.probe,
          onPutUp: _put,
          onAddToQueue: widget.onAddToQueue,
        ),
      MediaKind.file => _files(context),
    };

    final main = Column(
      children: [
        AnimatedSize(
          duration: easeTime,
          curve: ease,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: easeTime,
            child: widget.banner ?? const SizedBox(width: double.infinity),
          ),
        ),
        header,
        Expanded(child: fadeThrough(KeyedSubtree(key: ValueKey(source), child: content))),
      ],
    );

    final open = source == MediaKind.jellyfin && _c.selected != null;
    final shown = _shown;
    final details = shown == null
        ? const SizedBox.shrink()
        : fadeThrough(KeyedSubtree(
            key: ValueKey('${shown.serverId}/${shown.itemId}'),
            child: JellyfinDetailsPanel(
              controller: _browse,
              selection: shown,
              alone: widget.alone,
              onPutUp: _putUpJellyfin,
              onAddToQueue: widget.onAddToQueue == null ? null : _queueJellyfin,
              onClose: () => _c.select(null),
            ),
          ));
    Widget slide(Widget child) => AnimatedSlide(
          duration: easeTime,
          curve: ease,
          offset: open ? Offset.zero : const Offset(1, 0),
          child: AnimatedOpacity(duration: easeTime, curve: ease, opacity: open ? 1 : 0, child: child),
        );

    // Holds focus so the shell's shortcuts (Ctrl+,) work.
    return Focus(
      key: const ValueKey('library-tab'),
      autofocus: true,
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= detailsDockFrom) {
          return Row(
            children: [
              Expanded(child: main),
              ClipRect(
                child: AnimatedContainer(
                  duration: easeTime,
                  curve: ease,
                  width: open ? detailsPanelWidth : 0,
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: detailsPanelWidth,
                    maxWidth: detailsPanelWidth,
                    child: slide(details),
                  ),
                ),
              ),
            ],
          );
        }
        return Stack(
          children: [
            Positioned.fill(child: main),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: detailsPanelWidth,
              child: IgnorePointer(
                ignoring: !open,
                child: slide(Material(elevation: 16, child: details)),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _files(BuildContext context) {
    final relayed = !widget.isHost;
    Future<String?> play(String path) => _put(FileMedia(path));
    return SignalBuilder(builder: (context) {
      final graph = AppScope.of(context);
      final now = graph.navigation.online.value
          ? nowPlayingFile(graph.coordinator.serverState.value?.media, graph.forms.form.mediaPath)
          : null;
      final b = widget.filesBuilder;
      if (b != null) {
        return b(context, alone: widget.alone, relayed: relayed, onPlay: play, nowPlayingPath: now);
      }
      final add = widget.onAddToQueue;
      return FilesPage(
          alone: widget.alone,
          relayed: relayed,
          onPlay: play,
          onAddToQueue: add == null ? null : (path, {next = false}) => add(FileMedia(path), next: next),
          nowPlayingPath: now);
    });
  }
}

/// The current server's video libraries as chips in the Library header; a
/// click opens one (the chip of the library open is selected).
class _LibraryChips extends StatelessWidget {
  final BrowseController controller;
  const _LibraryChips({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.accounts]),
      builder: (context, _) {
        final accounts = controller.accounts;
        final account = accounts.loaded ? controller.account : null;
        final client = account == null ? null : accounts.clientFor(account.serverId);
        if (account == null || client == null) return const SizedBox(height: 40);
        final stack = controller.stack;
        final openId = stack.length > 1 && stack[1] is LibraryRoute ? (stack[1] as LibraryRoute).folder.id : null;
        return FutureBuilder<List<JellyfinItem>>(
          future: accounts.cached(account.serverId, 'views', client.userViews),
          builder: (context, snap) {
            final views = (snap.data ?? const <JellyfinItem>[]).where(isVideoLibrary).toList();
            return SizedBox(
              height: 40,
              child: HScroll(
                builder: (c) => ListView.separated(
                  controller: c,
                  scrollDirection: Axis.horizontal,
                  itemCount: views.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final v = views[i];
                    return Center(
                      child: ChoiceChip(
                        key: ValueKey('library-${v.id}'),
                        avatar: Icon(libraryIcon(v), size: 16),
                        showCheckmark: false,
                        label: Text(v.name),
                        selected: v.id == openId,
                        onSelected: (_) => v.id == openId
                            ? controller.popTo(0)
                            : controller.openTop(LibraryRoute(v)),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}
