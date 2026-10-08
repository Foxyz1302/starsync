import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/browse_scope.dart' show BrowseStart;
import '../jellyfin/session_media.dart';
import '../screens/home/connect_flow.dart';
import '../screens/home/health_probe.dart';
import '../screens/home/media_picker.dart';
import '../screens/home/profile.dart';
import '../screens/home/update_indicator.dart';
import '../state/session_state.dart';
import '../state/settings.dart';
import '../update/update_controller.dart';
import 'chat_panel.dart';
import 'connect_cards.dart';
import 'library_tab.dart';
import 'motion.dart';
import 'party_strip.dart';
import 'profile_card.dart';
import '../schedule/ui/schedule_page.dart';
import 'session_player.dart';
import 'settings_tab.dart';
import 'toasts.dart';

/// The one window: the party strip over a body that fades through between
/// the tabs and the full player, the floating mini player, the chat panel
/// and the toasts. Online/offline follows [SessionState.route].
///
/// The player ([SessionPlayer], the only `Video`) lives in one layer of
/// the body: full it fills the body (fullscreen: the window, strip
/// hidden), mini it is a 384x216 box snapped to a corner. A mode change
/// fades the layer out, moves it while invisible and fades it back in, so
/// the video is never mounted twice nor remounted.
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
  const AppShell({
    super.key,
    this.updates,
    this.autoUpdateCheck = true,
    this.windowControls = true,
    this.healthGet = defaultHealthGet,
    this.jellyfin,
    this.videoBuilder,
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

  Alignment _corner = Alignment.bottomRight;
  Offset? _drag; // mini top-left while dragging
  bool _snapping = false;

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
  double? _mutedVolume;
  bool _dialogOpen = false;
  String? _lastKickShown;
  final _stops = <void Function()>[];
  // Rebuild the shell on these flips, not on every state broadcast.
  final _online = computed(() => SessionState.instance.route.value == AppRoute.session);
  final _hasMedia = computed(() =>
      SessionState.instance.route.value == AppRoute.session &&
      SessionState.instance.coordinator.serverState.value?.media != null);

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
    _flow.onKicked = _showKicked;
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
    // Kicked: back offline, and say so.
    _stops.add(effect(() {
      final kick = coord.kickReason.value;
      if (kick == null) {
        _lastKickShown = null;
        return;
      }
      untracked(() {
        if (session.route.value == AppRoute.session) session.route.value = AppRoute.home;
      });
      if (kick.isNotEmpty) _later(() => _showKicked(kick));
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
    _fade.dispose();
    _online.dispose();
    _hasMedia.dispose();
    _flow.dispose();
    _join.dispose();
    _host.dispose();
    _picker.dispose();
    _chat.dispose();
    _chatFocus.dispose();
    if (_fullscreen) _setWindowFullscreen(false);
    super.dispose();
  }

  /// Runs [f] after the current signal notification / build.
  void _later(VoidCallback f) => scheduleMicrotask(() {
        if (mounted) f();
      });

  Future<void> _autoCheck() async {
    final s = AppSettings.instance;
    await s.ensureLoaded();
    if (s.autoCheckUpdates.peek()) await runUpdateCheck(widget.updates);
  }

  void _wentOnline() {
    _unread = 0;
    _feedSeen = SessionState.instance.coordinator.feedLog.peek().length;
    // Hosting starts with nothing up: the library is where to pick it.
    setState(() => _tab = ShellTab.library);
  }

  void _wentOffline() {
    _mutedVolume = null;
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
    if (m != PlayerMode.none) _unmute();
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

  /// Mini's ×: stop watching but stay in the server (muted until shown).
  void _closePlayer() {
    final playback = SessionState.instance.coordinator.playback;
    if (playback.alive.peek()) {
      try {
        _mutedVolume = playback.player.state.volume;
        playback.player.setVolume(0);
      } catch (_) {}
    }
    _show(PlayerMode.none);
  }

  void _unmute() {
    final v = _mutedVolume;
    if (v == null) return;
    _mutedVolume = null;
    final playback = SessionState.instance.coordinator.playback;
    if (!playback.alive.peek()) return;
    try {
      playback.player.setVolume(v);
    } catch (_) {}
  }

  Future<void> _setWindowFullscreen(bool on) async {
    if (!widget.windowControls) return;
    try {
      await windowManager.setFullScreen(on);
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

  /// Library → "Put it up for everyone"; the player opens full.
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

  // --------------------------------------------------------------- dialogs

  Future<void> _confirmLeave() async {
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

  Future<void> _showKicked(String reason) async {
    if (reason == _lastKickShown) return;
    _lastKickShown = reason;
    await _alert('You were removed', reason.isEmpty ? 'The host removed you from the server.' : reason);
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _selectTab(ShellTab.settings),
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : scheme.surface,
        body: SignalBuilder(builder: (context) {
          final online = _online.value;
          final hasMedia = _hasMedia.value;
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
                  onProfile: () => showProfileCard(context, onOpenSettings: _openSettings, updates: widget.updates),
                  onShowPlayer: hasMedia && _mode == PlayerMode.none ? () => _show(PlayerMode.mini) : null,
                  updates: widget.updates,
                  windowControls: widget.windowControls,
                ),
              Expanded(
                key: const ValueKey('body'),
                child: Row(
                  children: [
                    Expanded(child: _body(online)),
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
  }

  Widget _body(bool online) {
    final coord = SessionState.instance.coordinator;
    final tabBody = switch (_tab) {
      ShellTab.library => LibraryTab(
          key: ValueKey('library-$_libraryGen'),
          controller: _picker,
          accounts: _jellyfin,
          online: online,
          isHost: coord.hostFile != null,
          jellyfinStart: _libraryStart,
          onPutUp: _putUp,
          onOpenIntegrations: () => _openSettings(SettingsSection.integrations),
        ),
      ShellTab.schedule => SchedulePage(
          online: online,
          onPutUp: _putUp,
          onToast: coord.showToast,
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
          Positioned(left: 16, bottom: _fullscreen ? 90 : 16, child: const PartyToasts()),
        ],
      );
    });
  }

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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
