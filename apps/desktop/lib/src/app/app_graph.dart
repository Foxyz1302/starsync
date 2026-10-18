import 'package:flutter/widgets.dart';

import '../jellyfin/accounts.dart';
import '../library/library_store.dart';
import '../library/local_next.dart';
import '../library/show_matcher.dart';
import '../platform/app_log.dart' show appLogDir;
import '../platform/desktop/desktop_ports.dart';
import '../platform/ports/ports.dart';
import '../schedule/anilist.dart';
import '../schedule/animeflow.dart';
import '../screens/home/health_probe.dart';
import '../session/connection.dart' show Connection;
import '../session/identity.dart' show ClientIdentity, Profile;
import '../session/join_offers.dart';
import '../session/navigation.dart';
import '../session/notifier.dart';
import '../session/session_coordinator.dart';
import '../session/your_server.dart';
import '../sfx/sfx.dart';
import '../sfx/sound_bank.dart';
import '../sfx/synth_sfx.dart';
import '../state/connect_prefs.dart';
import '../state/settings.dart';
import '../update/update_controller.dart';
import '../update/whats_new.dart';
import '../watch/watch_history.dart';
import '../watch/watch_tracker.dart';

/// The composition root: builds the app's systems once (in `main`), wires
/// them through their constructors and disposes them. No logic and no
/// signals of its own. Widgets reach it through [AppScope].
class AppGraph {
  /// The platform (window, links, folders, yt-dlp, notifications).
  final Ports ports;

  /// Owns the app's audio device ([SynthSfx.dispose] on close).
  final SynthSfx sfx;

  /// Every toast, sound, system notification and activity-log line.
  final Notifier notifier;

  /// The link to whichever server this app is in.
  final Connection connection;

  final SessionCoordinator coordinator;

  /// The connect form and recent servers.
  final ConnectStore forms;

  /// This app's own server, alive for the whole run.
  final YourServer yourServer;

  /// Home (your server) or a friend's.
  final Navigation navigation;

  /// The library's matches (L2): local shows to AniList, pins, offsets.
  final ShowMatcher library;

  /// Watch tracking and the device's watch history (D3).
  final WatchTracker watch;

  /// The app's updater (checks, the update band, install and restart).
  final UpdateController updates;

  /// What's new once after an update; keeps the notes the updater saves.
  final WhatsNew whatsNew;

  /// The join prompt for a clicked invite link or one on the clipboard.
  final JoinOffers joinOffers;

  AppGraph._({
    required this.ports,
    required this.sfx,
    required this.notifier,
    required this.connection,
    required this.coordinator,
    required this.forms,
    required this.yourServer,
    required this.navigation,
    required this.library,
    required this.watch,
    required this.updates,
    required this.whatsNew,
    required this.joinOffers,
  });

  /// The desktop app's graph. Tests pass their own [ports], [identity]
  /// (default: the install's stored one), [healthGet], server starter and
  /// internet address lookup ([publicAddress]).
  factory AppGraph.build({
    Ports? ports,
    ClientIdentity? identity,
    HealthGetter healthGet = defaultHealthGet,
    ServerStarter? serverStarter,
    JellyfinAccounts? jellyfin,
    ShowMatcher? library,
    WatchHistory? history,
    Future<String?> Function()? publicAddress,
  }) {
    final p = ports ?? desktopPorts();
    final settings = AppSettings.instance;
    final sfx = SynthSfx(
      volume: () => settings.soundVolume.peek(),
      // A nudge is an explicit poke: it ignores its switch (not the volume).
      enabled: (k) => k == SfxKind.nudge || !settings.soundsOff.peek().contains(k.name),
      presetFor: soundPresetFor,
    );
    final notifier = Notifier(
      sfx: sfx,
      attention: p.shell.requestAttention,
      system: p.notifications,
      focusWindow: p.shell.focus,
      prefs: () => settings.notifyPrefs,
    );
    final connection = Connection(notify: notifier.notify, identity: identity ?? ClientIdentity.stored());
    // Device-owned: the watch history box.
    final watch = WatchTracker(history: history ?? WatchHistory());
    final coordinator = SessionCoordinator(
        notifier: notifier,
        connection: connection,
        ytDlp: p.links,
        jellyfin: jellyfin,
        players: p.players,
        settings: settings,
        watch: watch);
    // Device-owned: the library box; AnimeFlow's runs when signed in.
    final matcher = library ??
        ShowMatcher(
          store: HiveLibraryStore(),
          aniList: AniListClient(),
          flow: AnimeFlowLookup(AnimeFlowClient.fromAccounts(coordinator.jellyfin)),
        );
    coordinator
      ..fileRef = matcher.refForPath
      ..nextFile = LocalNextFinder(matcher: matcher, scan: p.folders.scan).nextAfter;
    final forms = ConnectStore();
    final yourServer = YourServer(
      forms: forms,
      jellyfin: jellyfin,
      // The app's yt-dlp folder; '' (the server's own default) when the
      // app-support folder is not available.
      ytDlpDir: () async {
        try {
          return (await p.links.ytDlp).dir;
        } catch (_) {
          return '';
        }
      },
      logDir: () => appLogDir,
      starter: serverStarter,
      publicAddress: publicAddress,
    );
    final navigation = Navigation(
      coordinator: coordinator,
      yourServer: yourServer,
      forms: forms,
      healthGet: healthGet,
    );
    // The profile keeps its name in the connect form and pushes changes
    // to whichever server this app is in.
    Profile.instance
      ..forms = forms
      ..push = ({String? name, String? avatar}) {
        if (navigation.online.peek()) coordinator.updateProfile(name: name, avatar: avatar);
      };
    final updates = UpdateController.instance;
    final whatsNew = WhatsNew(store: SettingsWhatsNewStore(settings));
    updates.beforeRestart ??= whatsNew.installing;
    return AppGraph._(
      ports: p,
      sfx: sfx,
      notifier: notifier,
      connection: connection,
      coordinator: coordinator,
      forms: forms,
      yourServer: yourServer,
      navigation: navigation,
      library: matcher,
      watch: watch,
      updates: updates,
      whatsNew: whatsNew,
      joinOffers: JoinOffers(navigation: navigation, yourServer: yourServer, forms: forms),
    );
  }

  Future<void> dispose() async {
    navigation.dispose();
    await coordinator.dispose();
    await watch.dispose();
    await yourServer.stop();
    await sfx.dispose();
  }
}

/// The sound set [kind] plays from: its own pick in Settings, else the
/// overall one.
SoundPreset soundPresetFor(SfxKind kind) {
  final s = AppSettings.instance;
  final name = s.soundPresetFor.peek()[kind.name] ?? s.soundPreset.peek();
  return SoundPreset.values.where((p) => p.name == name).firstOrNull ?? defaultPreset;
}

/// Hands the [AppGraph] to every widget below: `AppScope.of(context)`.
/// The graph never changes, so reading it registers no dependency (safe
/// in `initState`).
class AppScope extends InheritedWidget {
  final AppGraph graph;
  const AppScope({super.key, required this.graph, required super.child});

  static AppGraph of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'no AppScope above this widget');
    return scope!.graph;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => !identical(graph, oldWidget.graph);
}
