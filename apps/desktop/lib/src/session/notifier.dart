import 'dart:async';

import 'package:signals/signals_core.dart';
import 'package:sync_relay_core/core.dart' show FeedMessage, Presence;

import '../platform/ports/system_notifications.dart';
import '../platform/ports/window_activity.dart';
import '../sfx/sfx.dart';
import 'app_events.dart';
import 'notice_prefs.dart';

export 'app_events.dart';
export 'notice_prefs.dart';

class ToastItem {
  final int id;
  final String text;
  final DateTime at;
  /// The member a feed or chat toast is about (their name, as the feed
  /// carries it; [text] starts with it); null for the app's own toasts.
  final String? actor;
  /// [actor]'s member id (feed and chat toasts); '' when unknown.
  final String actorId;
  /// A chat message: a click opens the chat.
  final bool chat;
  /// A picture hash to show (an Up next item's), '' when none.
  final String thumb;
  /// What it is about (the shell may show some of it another way:
  /// "Notifications as danmaku").
  final NoticeCategory category;
  /// This member's own (their chat message coming back from the server).
  final bool own;
  const ToastItem(
      {required this.id,
      required this.text,
      required this.at,
      this.actor,
      this.actorId = '',
      this.chat = false,
      this.thumb = '',
      this.category = NoticeCategory.app,
      this.own = false});
}

/// What a notice is about; the policy filters by it ([noticeFor]).
enum NoticeCategory {
  /// Chat messages.
  chat,

  /// Someone poked this member.
  nudge,

  /// The media starts playing for the first time ("starting now").
  start,

  /// Up next and the video changing (adds, skips, swaps).
  upNext,

  /// Joins, leaves, lost signal and returns.
  people,

  /// The rest of what the party does (ready, seeks, pauses, someone sat
  /// out, renames): the activity log and a few sounds.
  party,

  /// Something keeps the watch from going smoothly (someone cannot play
  /// it, the source dropped, the server could not fetch it).
  problem,

  /// About this member itself (sat out, auto sit-out, the relay it
  /// serves, its connection, another window took over).
  self,

  /// The app's own notices (copied, shaders, update, errors): never
  /// filtered.
  app;

  /// What reaches you while you sit out or the window is in the
  /// background (D1): chat, nudges, "starting now" and Up next, plus joins
  /// and leaves when [NotifyPrefs.people] is on.
  bool reachesAway(NotifyPrefs prefs) => switch (this) {
        chat || nudge || start || upNext || self || app => true,
        people => prefs.people,
        party || problem => false,
      };

  /// Social: nothing of it plays or pops up while you watch alone (D9).
  bool get social => this == chat || this == start || this == people || this == party;

  /// May go out as a system notification while the window is in the
  /// background.
  bool get system => this == chat || this == nudge || this == start || this == upNext || this == people;
}

/// The session as the policy sees it.
typedef NoticeSession = ({Presence? self, bool alone, bool playing});

/// Where the user stands when a notice comes: their presence ([self],
/// null outside a session), whether anyone else is there ([alone]), the
/// window ([window]), whether the video plays ([playing]) and their
/// choices ([prefs]). A replayed feed line says so itself.
class NoticeContext {
  final Presence? self;
  final bool alone;
  final WindowActivity window;
  final bool playing;
  final NotifyPrefs prefs;
  /// The chat panel is open: chat is read there, not in pop-ups.
  final bool chatOpen;
  const NoticeContext({
    this.self,
    this.alone = false,
    this.window = WindowActivity.focused,
    this.playing = false,
    this.prefs = const NotifyPrefs(),
    this.chatOpen = false,
  });

  bool get away => self == Presence.away;
}

/// A notification outside the window ([SystemNotifications]).
class SystemNote {
  final String title;
  final String body;
  final String tag;
  /// [payloadChat]: a click opens the chat.
  final String payload;
  const SystemNote({required this.title, required this.body, this.tag = '', this.payload = ''});

  static const payloadChat = 'chat';
}

/// What one [AppEvent] does: a toast ([toast], about [actor]), a sound,
/// the window asking for attention, a system notification, an
/// activity-log line.
class Notice {
  final NoticeCategory category;
  final String? toast;
  final String? actor;
  /// The toast is a chat message (a click opens the chat).
  final bool chat;
  /// A picture hash for the toast (an Up next item's).
  final String thumb;
  /// This member is the actor (a feed line of its own).
  final bool own;
  final SfxCue? sound;
  final bool attention;
  final SystemNote? system;
  /// The feed line it goes into the activity log as.
  final FeedMessage? log;
  const Notice({
    this.category = NoticeCategory.app,
    this.toast,
    this.actor,
    this.chat = false,
    this.thumb = '',
    this.own = false,
    this.sound,
    this.attention = false,
    this.system,
    this.log,
  });

  static const none = Notice();

  Notice _with({bool toast = true, bool sound = true, SystemNote? system, bool own = false}) => Notice(
        category: category,
        toast: toast ? this.toast : null,
        actor: toast ? actor : null,
        chat: toast && chat,
        thumb: toast ? thumb : '',
        own: own,
        sound: sound ? this.sound : null,
        attention: attention,
        system: system,
        log: log,
      );
}

String _title(String t) => t.isEmpty ? 'the video' : t;

/// The event alone: its category, toast, sound and log line.
Notice _plain(AppEvent e) => switch (e) {
      // The feed: everything is logged.
      MemberJoined(:final feed) => Notice(
          category: NoticeCategory.people,
          log: feed,
          toast: '${feed.actor} joined',
          actor: feed.actor,
          sound: const SfxCue(SfxKind.join)),
      MemberLeft(:final feed) => Notice(
          category: NoticeCategory.people,
          log: feed,
          toast: '${feed.actor} left',
          actor: feed.actor,
          sound: const SfxCue(SfxKind.leave)),
      // After the server's delayed `gone` line (a quick reconnect says
      // nothing), and back after it.
      MemberGone(:final feed) => Notice(
          category: NoticeCategory.people, log: feed, toast: '${feed.actor} lost connection', actor: feed.actor),
      MemberReturned(:final feed) =>
        Notice(category: NoticeCategory.people, log: feed, toast: '${feed.actor} is back', actor: feed.actor),
      // Put back after a server restart: news, but not a change.
      MediaSwapped(:final feed) when feed.reason == 'restore' => Notice(
          category: NoticeCategory.upNext,
          log: feed,
          toast: '${feed.actor} put back what was playing',
          actor: feed.actor),
      MediaSwapped(:final feed) => Notice(
          category: NoticeCategory.upNext,
          log: feed,
          toast: '${feed.actor} changed media',
          actor: feed.actor,
          sound: const SfxCue(SfxKind.swap)),
      QueueAdded(:final feed, :final thumb) => Notice(
          category: NoticeCategory.upNext,
          log: feed,
          toast: '${feed.actor} added ${_title(feed.target ?? '')} to Up next',
          actor: feed.actor,
          thumb: thumb),
      QueueSkipped(:final feed) => Notice(
          category: NoticeCategory.upNext,
          log: feed,
          toast: 'Skipped ${feed.target ?? 'an item'}${feed.reason.isEmpty ? '' : ': ${feed.reason}'}'),
      QueueRemoved(:final feed) => Notice(category: NoticeCategory.upNext, log: feed),
      ChatPosted(:final feed) => Notice(
          category: NoticeCategory.chat,
          log: feed,
          toast: '${feed.actor}: ${feed.reason}',
          actor: feed.actor,
          chat: true,
          sound: const SfxCue(SfxKind.chat)),
      MemberSatOut(:final feed, atYou: true) => Notice(
          category: NoticeCategory.self,
          log: feed,
          toast: '${feed.actor} sat you out',
          actor: feed.actor,
          sound: const SfxCue(SfxKind.kick)),
      MemberSatOut(:final feed, autoSelf: true) => Notice(
          category: NoticeCategory.self,
          log: feed,
          toast: 'You sit out (${feed.reason == 'minimised' ? 'minimised' : 'idle'}); you are back as soon as you return',
          sound: const SfxCue(SfxKind.warn)),
      ReadyChanged(:final feed, ready: true, :final readyIndex) =>
        Notice(category: NoticeCategory.party, log: feed, sound: SfxCue(SfxKind.ready, readyIndex: readyIndex)),
      ReadyChanged(:final feed, ready: false) =>
        Notice(category: NoticeCategory.party, log: feed, sound: const SfxCue(SfxKind.unready)),
      ForcedReady(:final feed, ready: true) =>
        Notice(category: NoticeCategory.party, log: feed, sound: const SfxCue(SfxKind.forceReady)),
      FetchFailed(:final feed) => Notice(category: NoticeCategory.problem, log: feed),
      FeedEvent(:final feed) => Notice(category: NoticeCategory.party, log: feed),
      // The session.
      Nudged(:final name) => Notice(
          category: NoticeCategory.nudge,
          toast: '${name.isEmpty ? 'Someone' : name} nudged you',
          actor: name.isEmpty ? null : name,
          sound: const SfxCue(SfxKind.nudge),
          attention: true),
      PlaybackStarted(:final title) =>
        Notice(category: NoticeCategory.start, toast: title.isEmpty ? 'Starting now' : 'Starting now: $title'),
      MemberCantPlay(:final name, :final error) =>
        Notice(category: NoticeCategory.problem, toast: "$name can't play this: $error", actor: name),
      RelaySourceDropped(:final name, :final left) => Notice(
          category: NoticeCategory.problem,
          toast: left
              ? '$name left: playing what the server has'
              : "$name's connection dropped: playing what the server has",
          actor: name),
      SlowSource(:final text) => Notice(category: NoticeCategory.self, toast: text),
      RelayStarted() => const Notice(
          category: NoticeCategory.self,
          toast: 'Passing the video on through the server. Keep the app open while it plays.'),
      RelayFailed(:final error) => Notice(category: NoticeCategory.self, toast: 'Cannot pass the video on: $error'),
      ConnectionLost() => const Notice(category: NoticeCategory.self, sound: SfxCue(SfxKind.lost)),
      ConnectionBack() => const Notice(category: NoticeCategory.self, sound: SfxCue(SfxKind.back)),
      ServerRestarted() =>
        const Notice(category: NoticeCategory.self, toast: 'The server restarted; you are back in'),
      Replaced() => const Notice(category: NoticeCategory.self, toast: 'Starsync was opened in another window'),
      ServerRefused(:final text) => Notice(category: NoticeCategory.self, toast: text),
      JellyfinProgressFailed(:final signInExpired) =>
        Notice(toast: 'Jellyfin progress not saved: ${signInExpired ? 'sign-in expired' : 'server unreachable'}'),
      // The app.
      ShaderMessage(:final text) => Notice(toast: text),
      AddedToUpNext(:final title) => Notice(toast: 'Added $title to Up next'),
      ActionFailed(:final text) => Notice(toast: text),
      ScheduleResult(:final text) => Notice(toast: text),
      ProblemMarked(:final inSession) =>
        Notice(toast: inSession ? 'Marked in the session log' : "Marked in this app's log"),
      Copied(:final text) => Notice(toast: text),
      CopyFailed() => const Notice(toast: "Couldn't copy"),
      // The update band shows it (D8: a clear prompt, never over playback).
      UpdateAvailable() => Notice.none,
    };

/// The policy: what [e] does for a user in [c].
/// - Lines a reconnect replayed (`welcome.feed`): the activity log only.
/// - Your own joins, leaves, swaps and Up next adds: logged, no pop-up or
///   sound (the app already said so); your own chat pops up, silently.
/// - Alone (D9): no social sounds or pop-ups (nobody is there); the app's
///   notices, problems and your own still show.
/// - Sitting out (D1): only chat, nudges, "starting now", Up next, your
///   own and the app's, plus joins and leaves when chosen
///   ([NotifyPrefs.people]); the rest is logged only.
/// - "Starting now" pops up only while you sit out or the window is in
///   the background (otherwise you see it start).
/// - Chat pop-ups follow [NotifyPrefs.chat]; the chat sound has its own
///   switch (Settings → Sounds).
/// - The window in the background: what reaches you there also goes out
///   as a system notification (chat, nudges, "starting now", Up next;
///   joins and leaves when chosen).
Notice noticeFor(AppEvent e, [NoticeContext c = const NoticeContext()]) {
  if (e is FeedEvent && e.feed.replayed) return Notice(category: _plain(e).category, log: e.feed);
  final n = _plain(e);
  final cat = n.category;
  final own = e is FeedEvent && e.own;
  var toast = n.toast != null;
  var sound = n.sound != null;
  if (own && (cat == NoticeCategory.people || cat == NoticeCategory.upNext)) {
    toast = false;
    sound = false;
  }
  if (own && cat == NoticeCategory.chat) sound = false;
  if (c.alone && cat.social) {
    toast = false;
    sound = false;
  }
  if (c.away && !cat.reachesAway(c.prefs)) {
    toast = false;
    sound = false;
  }
  if (cat == NoticeCategory.start && !c.away && !c.window.background) toast = false;
  if (cat == NoticeCategory.chat && !c.prefs.chat.shows(playing: c.playing)) toast = false;
  // The open chat shows it already; the sound still plays.
  if (cat == NoticeCategory.chat && c.chatOpen && !c.window.background) toast = false;
  SystemNote? system;
  if (toast && !own && c.window.background && cat.system && cat.reachesAway(c.prefs)) {
    final actor = n.actor;
    final text = n.toast!;
    final body = actor != null && text.startsWith(actor) ? text.substring(actor.length).replaceFirst(RegExp(r'^:? '), '') : text;
    system = SystemNote(
      title: actor ?? 'Starsync',
      body: actor == null ? text : body,
      tag: cat == NoticeCategory.chat ? '' : cat.name,
      payload: cat == NoticeCategory.chat ? SystemNote.payloadChat : '',
    );
  }
  return n._with(toast: toast, sound: sound, system: system, own: own);
}

/// The one way news reaches the user: [notify] turns an [AppEvent] into
/// toasts ([toasts], each dropped after [toastLife] by the Notifier's
/// own timer), sounds, an attention request, a system notification and
/// the activity log ([feedLog]) per [noticeFor], in the context the
/// session ([session]), the window ([window]) and the user's choices
/// ([prefs]) give.
class Notifier {
  final SfxService sfx;
  final Future<void> Function() attention;
  final SystemNotifications system;
  /// Brings the window up (a click on a system notification).
  final Future<void> Function() focusWindow;
  final Duration toastLife;
  /// The session's part of the context; set by the coordinator.
  NoticeSession Function() session = () => (self: null, alone: false, playing: false);
  NotifyPrefs Function() prefs;
  /// The window's activity ([ShellPort.watchActivity], wired in `main`).
  WindowActivity window = WindowActivity.focused;

  /// The chat panel is open (set by the shell).
  bool chatOpen = false;

  Notifier({
    this.sfx = const NoopSfxService(),
    Future<void> Function()? attention,
    this.system = const NoSystemNotifications(),
    Future<void> Function()? focusWindow,
    this.toastLife = const Duration(seconds: 5),
    NotifyPrefs Function()? prefs,
  })  : attention = attention ?? _nothing,
        focusWindow = focusWindow ?? _nothing,
        prefs = prefs ?? _defaultPrefs {
    system.onClick = _clicked;
  }

  static Future<void> _nothing() async {}
  static NotifyPrefs _defaultPrefs() => const NotifyPrefs();

  /// Toasts on screen (the shell shows them).
  final toasts = signal<List<ToastItem>>([]);
  /// The activity log: the last 100 feed lines.
  final feedLog = signal<List<FeedMessage>>([]);
  /// Bumped when a click on a chat notification asks for the chat (the
  /// shell opens it).
  final chatRequests = signal(0);
  int _toastId = 0;
  final _timers = <int, Timer>{};

  NoticeContext get context {
    final s = session();
    return NoticeContext(
        self: s.self, alone: s.alone, window: window, playing: s.playing, prefs: prefs(), chatOpen: chatOpen);
  }

  void notify(AppEvent e) {
    final n = noticeFor(e, context);
    final log = n.log;
    if (log != null) {
      final all = [...feedLog.peek(), log];
      feedLog.value = all.length > 100 ? all.sublist(all.length - 100) : all;
    }
    final text = n.toast;
    if (text != null) {
      final id = ++_toastId;
      toasts.value = [
        ...toasts.peek(),
        ToastItem(
            id: id,
            text: text,
            at: DateTime.now().toUtc(),
            actor: n.actor,
            actorId: n.actor == null ? '' : n.log?.actorId ?? '',
            chat: n.chat,
            thumb: n.thumb,
            category: n.category,
            own: n.own),
      ];
      _timers[id] = Timer(toastLife, () => dismiss(id));
    }
    final sound = n.sound;
    if (sound != null) unawaited(sfx.play(sound));
    if (n.attention) unawaited(attention());
    final note = n.system;
    if (note != null) {
      unawaited(system.show(title: note.title, body: note.body, tag: note.tag, payload: note.payload));
    }
  }

  void _clicked(String payload) {
    unawaited(focusWindow());
    if (payload == SystemNote.payloadChat) chatRequests.value++;
  }

  /// Takes toast [id] off the screen (its time is up, or it was clicked).
  void dismiss(int id) {
    _timers.remove(id)?.cancel();
    final now = toasts.peek();
    if (now.any((t) => t.id == id)) toasts.value = [for (final t in now) if (t.id != id) t];
  }

  /// A new session: no toasts, an empty log.
  void clear() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    feedLog.value = [];
    toasts.value = [];
  }
}
