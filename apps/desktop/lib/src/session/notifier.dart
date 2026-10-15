import 'dart:async';

import 'package:signals/signals_core.dart';
import 'package:sync_relay_core/core.dart' show FeedMessage;

import '../sfx/sfx.dart';
import 'app_events.dart';

export 'app_events.dart';

class ToastItem {
  final int id;
  final String text;
  final DateTime at;
  /// The member a feed or chat toast is about (their name, as the feed
  /// carries it; [text] starts with it); null for the app's own toasts.
  final String? actor;
  const ToastItem({required this.id, required this.text, required this.at, this.actor});
}

/// What one [AppEvent] does: a toast ([toast], about [actor]), a sound,
/// the window asking for attention, an activity-log line.
class Notice {
  final String? toast;
  final String? actor;
  final SfxCue? sound;
  final bool attention;
  /// The feed line it goes into the activity log as.
  final FeedMessage? log;
  const Notice({this.toast, this.actor, this.sound, this.attention = false, this.log});

  static const none = Notice();
}

/// The policy: what each event does.
Notice noticeFor(AppEvent e) => switch (e) {
      // The feed: everything is logged; joins, leaves, swaps and chat
      // pop up; the social actions have a sound.
      MemberJoined(:final feed) => Notice(
          log: feed, toast: '${feed.actor} joined', actor: feed.actor, sound: const SfxCue(SfxKind.join)),
      MemberLeft(:final feed) => Notice(
          log: feed, toast: '${feed.actor} left', actor: feed.actor, sound: const SfxCue(SfxKind.leave)),
      MediaSwapped(:final feed) => Notice(
          log: feed, toast: '${feed.actor} changed media', actor: feed.actor, sound: const SfxCue(SfxKind.swap)),
      ChatPosted(:final feed, :final own) => Notice(
          log: feed,
          toast: '${feed.actor}: ${feed.reason}',
          actor: feed.actor,
          // Your own message needs no sound.
          sound: own ? null : const SfxCue(SfxKind.chat)),
      MemberSatOut(:final feed, atYou: true) => Notice(
          log: feed, toast: '${feed.actor} sat you out', actor: feed.actor, sound: const SfxCue(SfxKind.kick)),
      ReadyChanged(:final feed, ready: true, :final readyIndex) =>
        Notice(log: feed, sound: SfxCue(SfxKind.ready, readyIndex: readyIndex)),
      ReadyChanged(:final feed, ready: false) => Notice(log: feed, sound: const SfxCue(SfxKind.unready)),
      ForcedReady(:final feed, ready: true) => Notice(log: feed, sound: const SfxCue(SfxKind.forceReady)),
      QueueSkipped(:final feed) => Notice(
          log: feed, toast: 'Skipped ${feed.target ?? 'an item'}${feed.reason.isEmpty ? '' : ': ${feed.reason}'}'),
      FeedEvent(:final feed) => Notice(log: feed),
      // The session.
      Nudged(:final name) => Notice(
          toast: '${name.isEmpty ? 'Someone' : name} nudged you',
          actor: name.isEmpty ? null : name,
          sound: const SfxCue(SfxKind.nudge),
          attention: true),
      MemberCantPlay(:final name, :final error) => Notice(toast: "$name can't play this: $error", actor: name),
      SlowSource(:final text) => Notice(toast: text),
      RelayStarted() =>
        const Notice(toast: 'Passing the video on through the server. Keep the app open while it plays.'),
      RelayFailed(:final error) => Notice(toast: 'Cannot pass the video on: $error'),
      IdleWarning(:final sitsOut) => Notice(
          toast: sitsOut
              ? 'idle — sitting out in 2 min unless you press Space'
              : 'idle — auto-unready in 2 min unless you press Space',
          sound: const SfxCue(SfxKind.warn)),
      ConnectionLost() => const Notice(sound: SfxCue(SfxKind.lost)),
      ConnectionBack() => const Notice(sound: SfxCue(SfxKind.back)),
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
      // The update band shows it.
      UpdateAvailable() => Notice.none,
    };

/// The one way news reaches the user: [notify] turns an [AppEvent] into
/// toasts ([toasts]), sounds, an attention request and the activity log
/// ([feedLog]) per [noticeFor].
class Notifier {
  final SfxService sfx;
  final Future<void> Function() attention;
  Notifier({this.sfx = const NoopSfxService(), Future<void> Function()? attention})
      : attention = attention ?? _noAttention;

  static Future<void> _noAttention() async {}

  /// Toasts on screen (the shell shows them; [expire] drops old ones).
  final toasts = signal<List<ToastItem>>([]);
  /// The activity log: the last 100 feed lines.
  final feedLog = signal<List<FeedMessage>>([]);
  int _toastId = 0;

  void notify(AppEvent e) {
    final n = noticeFor(e);
    final log = n.log;
    if (log != null) {
      final all = [...feedLog.peek(), log];
      feedLog.value = all.length > 100 ? all.sublist(all.length - 100) : all;
    }
    final text = n.toast;
    if (text != null) {
      _toastId++;
      toasts.value = [
        ...toasts.peek(),
        ToastItem(id: _toastId, text: text, at: DateTime.now().toUtc(), actor: n.actor),
      ];
    }
    final sound = n.sound;
    if (sound != null) unawaited(sfx.play(sound));
    if (n.attention) unawaited(attention());
  }

  /// Drops toasts 4 s old or older.
  void expire(DateTime now) {
    toasts.value = toasts.peek().where((t) => now.difference(t.at).inSeconds < 4).toList();
  }

  /// A new session: no toasts, an empty log.
  void clear() {
    feedLog.value = [];
    toasts.value = [];
  }
}
