import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';

import '../controls/frame.dart' show DoubleClickListener;
import '../controls/session_controls.dart' show controlsBottomHeight;
import '../files/folder_store.dart';
import '../files/ui/files_page.dart' show showFilesFolder;
import '../jellyfin/accounts.dart';
import '../jellyfin/browse_scope.dart' show BrowseStart;
import '../jellyfin/session_media.dart';
import '../screens/home/connect_flow.dart';
import '../session/app_events.dart' show ActionFailed, ScheduleResult;
import '../session/session_coordinator.dart' show ConnectParams;
import '../screens/home/health_probe.dart';
import '../screens/home/media_picker.dart';
import '../session/identity.dart';
import '../screens/home/update_indicator.dart';
import '../state/session_state.dart';
import '../state/settings.dart';
import '../update/update_controller.dart';
import 'chat_panel.dart';
import 'connect_cards.dart';
import 'handoff.dart';
import 'library_link.dart' show LinkProber, defaultLinkProber;
import 'library_tab.dart';
import 'motion.dart';
import 'party_strip.dart';
import 'profile_card.dart';
import '../schedule/ui/schedule_page.dart';
import 'session_player.dart';
import 'settings_tab.dart';
import 'toasts.dart';
import 'welcome.dart';

/// The one window: the party strip over a body that fades through between
/// the tabs and the full player, the floating mini player, the chat panel
/// and the toasts. Online/offline follows [SessionState.route].
///
/// The player ([SessionPlayer], the only `Video`) lives in one layer of
/// the body: full it fills the body (fullscreen: the window, strip
/// hidden), mini it is a 384x216 box snapped to a corner. A mode change
/// fades the layer out, moves it while invisible and fades it back in, so
/// the video is never mounted twice nor remounted.
///
/// A drop anywhere on the window or Ctrl+V outside a text field is a
/// [Handoff]: a card near the pointer asks how to open it.
class AppShell extends StatefulWidget {
  final UpdateController? updates;
  final bool autoUpdateCheck;
  /// Off in tests: the drag area, window buttons and fullscreen need
  /// window_manager.
  final bool windowControls;
  final HealthGetter healthGet;
  /// Linked Jellyfin servers; defaults to [JellyfinAccounts.instance].
  final JellyfinAccounts? jellyfin;
  /// Stand-in for media_kit's `Video` (tests).
  final VideoViewBuilder? videoBuilder;
  /// What the Library's Link page asks about a link (tests: a fake, so no
  /// network or yt-dlp runs).
  final LinkProber linkProbe;
  const AppShell({
    super.key,
    this.updates,
    this.autoUpdateCheck = true,
    this.windowControls = true,
    this.healthGet = defaultHealthGet,
    this.jellyfin,
    this.videoBuilder,
    this.linkProbe = defaultLinkProber,
  });

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> with SingleTickerProviderStateMixin {
  static const miniSize = Size(384, 216);
  static const _miniMargin = 16.0;

  ShellTab _tab = ShellTab.library;
  SettingsSection _section = SettingsSection.profile;

  /// Where the player is going ([_mode]) and where it is drawn ([_shown]):
  /// they differ for the first part of a change, while it fades out.
  PlayerMode _mode = PlayerMode.none;
  PlayerMode _shown = PlayerMode.none;
  PlayerMode _from = PlayerMode.none;
  int _modeSeq = 0;
  late final AnimationController _fade = AnimationController(vsync: this, value: 1);

  bool _fullscreen = false;
  bool _chatOpen = false;
  int _unread = 0;
  int _feedSeen = 0;
  final _chat = TextEditingController();
  final _chatFocus = FocusNode();
  final _playerKey = GlobalKey();
  /// Whether the full player's controls are up (the player's frame
  /// reports it): the toasts sit above them.
  final _controlsShown = ValueNotifier(true);

  Alignment _corner = Alignment.bottomRight;
  Offset? _drag; // mini top-left while dragging
  bool _snapping = false;

  /// Last pointer position in the window (where a paste's card opens).
  Offset? _pointer;
  bool _dragging = false;
  bool _handoffOpen = false;

  final _flow = ConnectFlow();
  late final _join = JoinFields(SessionState.instance.lastForm);
  late final _host = HostFields(SessionState.instance.lastForm);
  late final JellyfinAccounts _jellyfin = widget.jellyfin ?? JellyfinAccounts.instance;
  late MediaPickerController _picker = _newPicker();
  BrowseStart? _libraryStart;
  int _libraryGen = 0;

  /// The next media to come up opens full (just joined, or put up here).
  bool _autoFull = false;
  int _lastMediaId = -1;
  bool _dialogOpen = false;
  final _stops = <void Function()>[];
  // Rebuild the shell on these flips, not on every state broadcast.
  final _online = computed(() => SessionState.instance.route.value == AppRoute.session);
  /// Nobody else watches: offline, solo, or solo becoming a server.
  final _alone = computed(() {
    final s = SessionState.instance;
    return s.route.value != AppRoute.session || s.solo.value || s.switching.value;
  });
  final _hasMedia = computed(() =>
      SessionState.instance.route.value == AppRoute.session &&
      SessionState.instance.coordinator.serverState.value?.media != null);

  /// A video is on in the session (not finished): the update bar stays
  /// off the full player.
  final _watching = computed(() {
    final s = SessionState.instance;
    final r = s.coordinator.serverState.value;
    return s.route.value == AppRoute.session && r?.media != null && r?.transport != 'finished';
  });

  PlayerMode get mode => _mode;
  PlayerMode get shownMode => _shown;
  bool get fullscreen => _fullscreen;

  MediaPickerController _newPicker({JellyfinMedia? jellyfin, MediaKind? source}) {
    final f = SessionState.instance.lastForm;
    final c = MediaPickerController(mediaPath: f.mediaPath, linkUrl: f.linkUrl, jellyfin: jellyfin, source: source);
    if (jellyfin == null) unawaited(restoreLastPick(c, _jellyfin, () => mounted && identical(c, _picker)));
    return c;
  }

  @override
  void initState() {
    super.initState();
    unawaited(Profile.instance.ensureLoaded());
    // Reads linked servers and checks their tokens in the background.
    _jellyfin.ensureLoaded();
    if (widget.autoUpdateCheck) _autoCheck();
    HardwareKeyboard.instance.addHandler(_onKey);
    final session = SessionState.instance;
    final coord = session.coordinator;
    _feedSeen = coord.feedLog.peek().length;
    _stops.add(effect(() {
      final online = session.route.value == AppRoute.session;
      // Set now, not later: the media effect below may run first in this
      // same flush, and its scheduled show reads these.
      _autoFull = online;
      if (!online) _lastMediaId = -1;
      untracked(() => _later(() => online ? _wentOnline() : _wentOffline()));
    }));
    // Something comes up while the player is closed: show it (full right
    // after joining or a put-up of ours, else as the mini player).
    _stops.add(effect(() {
      final r = coord.serverState.value;
      final online = session.route.value == AppRoute.session;
      if (!online || r == null || r.media == null) return;
      if (r.mediaId == _lastMediaId) return;
      _lastMediaId = r.mediaId;
      _later(() {
        if (_mode == PlayerMode.none) {
          _show(_autoFull ? PlayerMode.full : PlayerMode.mini);
        } else if (_autoFull) {
          _show(PlayerMode.full);
        }
        _autoFull = false;
      });
    }));
    // A click on a chat system notification: the window is up, open the
    // chat.
    var chatAsks = coord.notifier.chatRequests.peek();
    _stops.add(effect(() {
      final asks = coord.notifier.chatRequests.value;
      if (asks == chatAsks) return;
      chatAsks = asks;
      _later(() {
        if (!_chatOpen && _online.peek()) _toggleChat();
      });
    }));
    // Chat that arrives while the panel is closed.
    _stops.add(effect(() {
      final log = coord.feedLog.value;
      final fresh = log.length < _feedSeen ? log : log.sublist(_feedSeen);
      _feedSeen = log.length;
      final chats = fresh.where((f) => f.action == 'chat').length;
      if (chats == 0) return;
      untracked(() => _later(() {
            if (!_chatOpen) setState(() => _unread += chats);
          }));
    }));
    // Back from sitting out with the player closed: show it (the media
    // plays again).
    var wasOut = false;
    _stops.add(effect(() {
      final out = coord.selfAway.value;
      if (wasOut && !out && session.route.peek() == AppRoute.session) {
        _later(() {
          if (_mode == PlayerMode.none) _show(PlayerMode.mini);
        });
      }
      wasOut = out;
    }));
    // Solo becoming a hosted server: the player closes while the media
    // moves over and comes back the way it was once it is up again.
    _stops.add(effect(() {
      if (!session.switching.value) return;
      _later(() {
        _lastMediaId = -1;
        _autoFull = _mode == PlayerMode.full;
        if (_fullscreen) _toggleFullscreen();
        _show(PlayerMode.none);
      });
    }));
    // The hosted server died mid-session (SessionState leaves): say so.
    _stops.add(effect(() {
      final crash = session.serverCrash.value;
      if (crash == null) return;
      _later(() {
        session.serverCrash.value = null;
        _alert('Server crashed', crash);
      });
    }));
  }

  @override
  void dispose() {
    for (final stop in _stops) {
      stop();
    }
    HardwareKeyboard.instance.removeHandler(_onKey);
    _updateTimer?.cancel();
    _fade.dispose();
    _online.dispose();
    _alone.dispose();
    _hasMedia.dispose();
    _watching.dispose();
    _flow.dispose();
    _join.dispose();
    _host.dispose();
    _picker.dispose();
    _chat.dispose();
    _chatFocus.dispose();
    _controlsShown.dispose();
    if (_fullscreen) _setWindowFullscreen(false);
    super.dispose();
  }

  /// Runs [f] after the current signal notification / build.
  void _later(VoidCallback f) => scheduleMicrotask(() {
        if (mounted) f();
      });

  Timer? _updateTimer;

  /// At start, then every [updateCheckEvery] while the app runs (when the
  /// auto-check setting is on).
  Future<void> _autoCheck() async {
    final s = AppSettings.instance;
    await s.ensureLoaded();
    if (!mounted) return;
    _updateTimer = Timer.periodic(updateCheckEvery, (_) {
      if (s.autoCheckUpdates.peek()) unawaited(runUpdateCheck(widget.updates, true));
    });
    if (s.autoCheckUpdates.peek()) await runUpdateCheck(widget.updates);
  }

  void _wentOnline() {
    _unread = 0;
    _feedSeen = SessionState.instance.coordinator.feedLog.peek().length;
    // Hosting starts with nothing up: the library is where to pick it.
    setState(() => _tab = ShellTab.library);
  }

  void _wentOffline() {
    if (_fullscreen) _toggleFullscreen();
    setState(() {
      _chatOpen = false;
      _unread = 0;
    });
    _show(PlayerMode.none);
  }

  // ----------------------------------------------------------- player mode

  /// Fade through to [m]: the player layer (and, when full is involved,
  /// the tabs) fades out, moves while invisible, then fades in.
  Future<void> _show(PlayerMode m) async {
    if (m == _mode) return;
    final seq = ++_modeSeq;
    setState(() {
      _from = _shown;
      _mode = m;
    });
    if (m == PlayerMode.full) FocusManager.instance.primaryFocus?.unfocus();
    if (_shown != PlayerMode.none || m == PlayerMode.full) {
      await _fade.animateTo(0,
          duration: fadeThroughTime * fadeOutPart, curve: Curves.easeIn);
    } else {
      _fade.value = 0;
    }
    if (!mounted || seq != _modeSeq) return;
    setState(() => _shown = m);
    await _fade.animateTo(1, duration: fadeThroughTime * (1 - fadeOutPart), curve: ease);
  }

  void _expand() => _show(PlayerMode.full);

  void _collapse() {
    if (_fullscreen) _toggleFullscreen();
    _show(PlayerMode.mini);
  }

  /// The player's ×: sit out (stay in the server, nothing loaded; the
  /// player shows the join-back card). Once out, × closes the player.
  void _closePlayer() {
    final coord = SessionState.instance.coordinator;
    if (coord.selfAway.peek()) {
      _show(PlayerMode.none);
    } else {
      coord.sitOut();
    }
  }

  Future<void> _setWindowFullscreen(bool on) async {
    if (!widget.windowControls) return;
    try {
      await SessionState.instance.ports.shell.setFullScreen(on);
    } catch (_) {
      // No window manager.
    }
  }

  void _toggleFullscreen() {
    final on = !_fullscreen;
    setState(() => _fullscreen = on);
    if (on && _mode != PlayerMode.full) _show(PlayerMode.full);
    _setWindowFullscreen(on);
  }

  void _selectTab(ShellTab t) {
    if (_fullscreen) _toggleFullscreen();
    setState(() => _tab = t);
    if (_mode == PlayerMode.full) _show(PlayerMode.mini);
  }

  void _openSettings(SettingsSection s) {
    setState(() => _section = s);
    _selectTab(ShellTab.settings);
  }

  void _toggleChat() => setState(() {
        _chatOpen = !_chatOpen;
        _unread = 0;
        if (!_chatOpen) _chatFocus.unfocus();
      });

  // --------------------------------------------------------------- library

  /// "Change video": the library, opened on the series of the episode
  /// playing (season selected, episode highlighted), else where it was.
  void _changeVideo() {
    final coord = SessionState.instance.coordinator;
    coord.markInput();
    final ref = coord.currentRef.peek();
    final pick = ref == null ? null : pickForRef(_jellyfin, ref);
    final plan = coord.jellyfinPlan.peek();
    final old = _picker;
    _picker = pick == null
        ? _newPicker()
        : _newPicker(jellyfin: pick, source: MediaKind.jellyfin);
    old.dispose();
    _libraryStart = ref != null && plan is OwnPlay && plan.item != null
        ? BrowseStart.seriesOf(ref.serverId, plan.item!)
        : null;
    _libraryGen++;
    _selectTab(ShellTab.library);
  }

  /// Library → "Put it up for everyone"; the player opens full. Offline
  /// it starts a solo session first (just you, on this computer).
  Future<String?> _putUp(PickedMedia media) async {
    final session = SessionState.instance;
    if (media is JellyfinMedia) {
      try {
        putUpJellyfinMedia(_jellyfin, media);
      } on FormatException catch (e) {
        return e.message;
      }
      unawaited(_jellyfin.rememberPick(media));
    }
    if (!_online.peek()) {
      final error = await _startSolo();
      if (error != null || !mounted) return error;
    }
    // Alone, a link plays direct: there is nobody to pass it on to.
    if (media is LinkMedia && session.solo.peek()) {
      media = LinkMedia(media.url, relay: LinkRelay.direct, anyway: media.anyway);
    }
    final error = await session.coordinator.swapPicked(media);
    if (error != null || !mounted) return error;
    final f = session.lastForm;
    f
      ..linkUrl = media is LinkMedia ? media.url : f.linkUrl
      ..mediaPath = media is FileMedia ? media.path : f.mediaPath;
    unawaited(session.saveForm().catchError((Object _) {}));
    _autoFull = true;
    _show(PlayerMode.full);
    return null;
  }

  /// Starts a solo session; returns an error text, or null.
  Future<String?> _startSolo() async {
    final profile = Profile.instance;
    try {
      await profile.ensureLoaded();
      final name = profile.name.peek().trim();
      await SessionState.instance.startSolo(ConnectParams(
        host: '127.0.0.1',
        port: 0,
        secret: '',
        name: name.isEmpty ? 'Me' : name,
        avatar: profile.avatarBase64(),
      ));
      return null;
    } catch (e) {
      return "couldn't start playing: $e";
    }
  }

  /// Library's "Watch solo": somewhere to pick from (Jellyfin when linked,
  /// else Files).
  void _watchSolo() => _openLibrary(_jellyfin.isEmpty ? MediaKind.file : MediaKind.jellyfin);

  // --------------------------------------------------------------- handoff

  /// Nothing (a dialog, a popover) is over the shell.
  bool get _onTop => !_handoffOpen && handoffHolds == 0 && (ModalRoute.of(context)?.isCurrent ?? true);

  /// Ctrl+V outside a text field (a focused field pastes on its own).
  bool _onKey(KeyEvent e) {
    // Any key is activity (auto sit-out).
    SessionState.instance.coordinator.markInput();
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyV) return false;
    final keys = HardwareKeyboard.instance;
    if (!(keys.isControlPressed || keys.isMetaPressed) || keys.isShiftPressed || keys.isAltPressed) return false;
    if (!mounted || !_onTop) return false;
    final inField =
        FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;
    if (inField) return false;
    unawaited(_paste());
    return true;
  }

  /// Clipboard files first, then text (a link or absolute paths). A pasted
  /// image has no taker yet, so the clipboard's image data is not read.
  Future<void> _paste() async {
    final clip = await SessionState.instance.ports.shell.readPaste();
    await _handOff(classifyHandoff(paths: clip.files, text: clip.text), _pointer);
  }

  Future<void> _handOff(Handoff item, Offset? at) async {
    if (!mounted || !_onTop || item is HandoffNothing || item is HandoffImage) return;
    final size = MediaQuery.sizeOf(context);
    final align = at == null || size.isEmpty
        ? Alignment.center
        : Alignment((at.dx / size.width * 2 - 1).clamp(-1, 1), (at.dy / size.height * 2 - 1).clamp(-1, 1));
    _handoffOpen = true;
    final HandoffAction? action;
    try {
      action = await showPopover<HandoffAction>(context,
          at: align, child: HandoffCard(item: item, solo: _alone.peek(), queue: _online.peek()));
    } finally {
      _handoffOpen = false;
    }
    if (action == null || !mounted) return;
    switch ((item, action)) {
      case (HandoffVideos(:final paths), HandoffAction.putUp):
        final error = await _putUp(FileMedia(paths.first));
        if (error != null) {
          SessionState.instance.coordinator.notify(ActionFailed(error));
        } else {
          await FolderStore.instance.ensureLoaded();
          FolderStore.instance.addRecent(paths.first);
        }
      case (HandoffVideos(:final paths), HandoffAction.queue || HandoffAction.playNext):
        // In order: with Play next, the last one added goes first.
        final next = action == HandoffAction.playNext;
        for (final p in next ? paths.reversed : paths) {
          final error = await SessionState.instance.coordinator.queue.add(FileMedia(p), next: next);
          if (error != null) {
            SessionState.instance.coordinator.notify(ActionFailed(error));
            break;
          }
        }
      case (HandoffLink(:final url), HandoffAction.queue || HandoffAction.playNext):
        // In the Link page's mode, probed and refused like there.
        final coord = SessionState.instance.coordinator;
        final error = await coord.queue
            .add(LinkMedia(url, relay: _picker.linkRelay), next: action == HandoffAction.playNext);
        if (error != null) coord.notify(ActionFailed(error));
      case (HandoffVideos(:final paths), HandoffAction.addFolder):
        await _addFolder(File(paths.first).parent.path);
      case (HandoffFolder(:final path), _):
        await _addFolder(path);
      case (HandoffLink(:final url), _):
        _picker.link.text = url;
        _openLibrary(MediaKind.link);
      default:
    }
  }

  Future<void> _addFolder(String dir) async {
    await FolderStore.instance.ensureLoaded();
    FolderStore.instance.addFolder(dir);
    _openFiles(dir);
  }

  /// Library → Files on [dir] (null: Recent).
  void _openFiles(String? dir) {
    showFilesFolder(dir);
    _openLibrary(MediaKind.file);
  }

  void _openLibrary(MediaKind source) {
    if (!mounted) return;
    _picker.source = source;
    _selectTab(ShellTab.library);
  }

  // Off on Settings: its own drop targets (cookies) take the files there.
  Widget _dropTarget(Widget child) => SessionState.instance.ports.shell.dropTarget(
        enable: _tab != ShellTab.settings,
        onEnter: () => setState(() => _dragging = _onTop),
        onExit: () => setState(() => _dragging = false),
        onDrop: (paths, at) {
          setState(() => _dragging = false);
          _handOff(classifyHandoff(paths: paths), at);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: easeTime,
                  curve: ease,
                  opacity: _dragging ? 1 : 0,
                  child: const _DropOverlay(),
                ),
              ),
            ),
          ],
        ),
      );

  // --------------------------------------------------------------- dialogs

  /// Leave asks first; a solo session just stops.
  Future<void> _confirmLeave() async {
    final session = SessionState.instance;
    if (session.solo.peek()) {
      await session.leave();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave server?'),
        content: const Text('You can rejoin right away.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('confirm-leave'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok == true) await SessionState.instance.leave();
  }

  Future<void> _alert(String title, String text) async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  void _connect(ConnectMode mode) => showConnectCard(
        context,
        mode: mode,
        flow: _flow,
        join: _join,
        host: _host,
        healthGet: widget.healthGet,
      );

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shell = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _selectTab(ShellTab.settings),
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : scheme.surface,
        body: SignalBuilder(builder: (context) {
          final online = _online.value;
          final alone = _alone.value;
          final hasMedia = _hasMedia.value;
          final onPlayer = _shown == PlayerMode.full && _watching.value;
          return Column(
            children: [
              if (!_fullscreen)
                PartyStrip(
                  key: const ValueKey('strip'),
                  tab: _tab,
                  onTab: _selectTab,
                  chatOpen: _chatOpen,
                  unread: _unread,
                  onChat: _toggleChat,
                  onJoin: () => _connect(ConnectMode.join),
                  onHost: () => _connect(ConnectMode.host),
                  onLeave: _confirmLeave,
                  onInvite: () => _connect(ConnectMode.host),
                  onProfile: () => showProfileCard(context, onOpenSettings: _openSettings, updates: widget.updates),
                  onShowPlayer: hasMedia && _mode == PlayerMode.none ? () => _show(PlayerMode.mini) : null,
                  windowControls: widget.windowControls,
                ),
              AnimatedSize(
                duration: easeTime,
                curve: ease,
                alignment: Alignment.topCenter,
                child: _fullscreen || onPlayer ? const SizedBox(width: double.infinity) : UpdateBar(controller: widget.updates),
              ),
              Expanded(
                key: const ValueKey('body'),
                child: Row(
                  children: [
                    Expanded(child: _body(online, alone)),
                    AnimatedSize(
                      duration: easeTime,
                      curve: ease,
                      alignment: Alignment.centerLeft,
                      child: _chatOpen && online
                          ? ChatPanel(chat: _chat, chatFocus: _chatFocus, onClose: _toggleChat)
                          : const SizedBox(height: double.infinity),
                    ),
                  ],
                ),
              ),
            ],
          );
        }),
      ),
    );
    // Any pointer use anywhere is activity (auto sit-out).
    final coord = SessionState.instance.coordinator;
    return Listener(
      onPointerHover: (e) {
        _pointer = e.localPosition;
        coord.markInput();
      },
      onPointerDown: (e) {
        _pointer = e.localPosition;
        coord.markInput();
      },
      onPointerSignal: (_) => coord.markInput(),
      child: _dropTarget(shell),
    );
  }

  /// No Jellyfin account, no server joined or hosted yet, band not
  /// dismissed: the welcome band explains the three ways in.
  bool get _newcomer =>
      !AppSettings.instance.welcomeDismissed.value &&
      _jellyfin.isEmpty &&
      SessionState.instance.recents.value.isEmpty;

  Widget _body(bool online, bool alone) {
    final coord = SessionState.instance.coordinator;
    final tabBody = switch (_tab) {
      ShellTab.library => LibraryTab(
          key: ValueKey('library-$_libraryGen'),
          controller: _picker,
          accounts: _jellyfin,
          solo: alone,
          // Offline, a put-up starts a solo session, which hosts.
          isHost: !online || coord.hostFile != null,
          // Only for newcomers: the strip has Join and Host for everyone else.
          banner: online || !_newcomer
              ? null
              : WelcomeBand(
                  onJoin: () => _connect(ConnectMode.join),
                  onHost: () => _connect(ConnectMode.host),
                  onSolo: _watchSolo,
                  onDismiss: () => setState(AppSettings.instance.dismissWelcome),
                ),
          jellyfinStart: _libraryStart,
          onPutUp: _putUp,
          // Up next needs a server (a solo session has one).
          onAddToQueue: online ? coord.queue.add : null,
          onOpenIntegrations: () => _openSettings(SettingsSection.integrations),
          probe: widget.linkProbe,
        ),
      ShellTab.schedule => SchedulePage(
          solo: alone,
          onPutUp: _putUp,
          onAddToQueue: online ? coord.queue.add : null,
          onToast: (text) => coord.notify(ScheduleResult(text)),
        ),
      ShellTab.settings => SettingsTab(
          section: _section,
          onSection: (s) => setState(() => _section = s),
          onEditProfile: () => showProfileCard(context, onOpenSettings: _openSettings, updates: widget.updates),
          updates: widget.updates,
          jellyfin: _jellyfin,
        ),
    };
    final full = _shown == PlayerMode.full;
    final fullInvolved = _mode == PlayerMode.full || _from == PlayerMode.full;
    return LayoutBuilder(builder: (context, box) {
      final area = box.biggest;
      return Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _fade,
              builder: (context, child) {
                // The tabs take part in the fade only when the full player
                // comes or goes; a mini player appearing leaves them be.
                final v = full ? 0.0 : (fullInvolved ? _fade.value : 1.0);
                return Opacity(
                  opacity: v,
                  child: Transform.scale(scale: 0.985 + 0.015 * v, child: child),
                );
              },
              child: IgnorePointer(
                ignoring: full,
                child: ExcludeFocus(
                  excluding: full,
                  child: TickerMode(
                    enabled: !full,
                    child: fadeThrough(KeyedSubtree(key: ValueKey(_tab), child: tabBody)),
                  ),
                ),
              ),
            ),
          ),
          if (online && _shown != PlayerMode.none) _playerLayer(area),
          _toasts(full && online),
        ],
      );
    });
  }

  /// The toasts, bottom left; over the full player above its control
  /// bar (the bar's height in the skin and size in use), moving up while
  /// the controls show and down while they are hidden, so they never
  /// cover the controls (both skins).
  Widget _toasts(bool overPlayer) {
    final toasts = PartyToasts(
      onOpenChat: () {
        if (!_chatOpen) _toggleChat();
      },
    );
    return ValueListenableBuilder<bool>(
      valueListenable: _controlsShown,
      builder: (context, shown, child) => SignalBuilder(builder: (context) {
        final s = AppSettings.instance;
        final bar = controlsBottomHeight(s.controlsSkin.value, s.controlsSize.value);
        return AnimatedPositioned(
          key: const ValueKey('toasts'),
          duration: easeTime,
          curve: ease,
          left: toastInset,
          bottom: overPlayer && shown ? bar + toastInset : toastInset,
          child: child!,
        );
      }),
      child: toasts,
    );
  }

  /// The toasts' distance from the body's left and bottom edges (and from
  /// the player's control bar).
  static const toastInset = 16.0;

  Offset _cornerPos(Size area, Alignment a, Size size) => Offset(
        a.x < 0 ? _miniMargin : (area.width - size.width - _miniMargin).clamp(0, double.infinity),
        a.y < 0 ? _miniMargin : (area.height - size.height - _miniMargin).clamp(0, double.infinity),
      );

  Widget _playerLayer(Size area) {
    final mini = _shown == PlayerMode.mini;
    final size = mini
        ? Size(miniSize.width.clamp(0, area.width), miniSize.height.clamp(0, area.height))
        : area;
    final pos = mini ? (_drag ?? _cornerPos(area, _corner, size)) : Offset.zero;
    return AnimatedPositioned(
      key: const ValueKey('player-layer'),
      duration: _snapping ? easeTime : Duration.zero,
      curve: ease,
      left: pos.dx,
      top: pos.dy,
      width: size.width,
      height: size.height,
      onEnd: () => _snapping = false,
      child: AnimatedBuilder(
        animation: _fade,
        builder: (context, child) {
          final v = _fade.value;
          return IgnorePointer(
            ignoring: v < 0.5 || _shown != _mode,
            child: Opacity(
              opacity: v,
              child: Transform.scale(scale: mini ? 0.97 + 0.03 * v : 0.985 + 0.015 * v, child: child),
            ),
          );
        },
        // Same widgets in both modes (only their settings change), so the
        // player below never moves in the element tree.
        child: GestureDetector(
          onPanStart: mini ? (_) => setState(() => _drag = pos) : null,
          onPanUpdate: mini ? (d) => setState(() => _drag = _drag! + d.delta) : null,
          onPanEnd: mini
              ? (_) => setState(() {
                    final c = _drag! + Offset(size.width / 2, size.height / 2);
                    _corner = Alignment(c.dx < area.width / 2 ? -1 : 1, c.dy < area.height / 2 ? -1 : 1);
                    _drag = null;
                    _snapping = true;
                  })
              : null,
          child: DoubleClickListener(
            onDoubleClick: mini ? _expand : () {},
            skipTop: 40,
            skipBottom: 60,
            child: Material(
              elevation: mini ? 16 : 0,
              color: Colors.black,
              borderRadius: BorderRadius.circular(mini ? 14 : 0),
              clipBehavior: Clip.antiAlias,
              child: KeyedSubtree(
                key: _playerKey,
                child: SessionPlayer(
                  mode: _shown,
                  fullscreen: _fullscreen,
                  chatOpen: _chatOpen,
                  unread: _unread,
                  onExpand: _expand,
                  onCollapse: _collapse,
                  onClose: _closePlayer,
                  onToggleFullscreen: _toggleFullscreen,
                  onToggleChat: _toggleChat,
                  onChangeVideo: _changeVideo,
                  onOpenIntegrations: () => _openSettings(SettingsSection.integrations),
                  onLeave: _confirmLeave,
                  videoBuilder: widget.videoBuilder,
                  windowControls: widget.windowControls,
                  controlsShown: _controlsShown,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Over the window while something is dragged over it.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('drop-overlay'),
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.7), width: 2),
      ),
      alignment: Alignment.center,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.file_download_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              Text('Drop to open', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }
}
