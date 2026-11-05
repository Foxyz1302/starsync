// The Notifier policy as a table: one row per AppEvent subtype in the
// plain context (in, with others, the window focused, paused, default
// choices), then the rows that change with the context (sitting out,
// alone, the window in the background, playing, a replayed line). What
// noticeFor makes of each: toast text and actor, sound, attention, system
// notification, activity-log line. A policy change edits a row here on
// purpose.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show FeedMessage, Presence;
import 'package:starsync/src/platform/ports/system_notifications.dart';
import 'package:starsync/src/platform/ports/window_activity.dart';
import 'package:starsync/src/session/notifier.dart';
import 'package:starsync/src/sfx/sfx.dart';

final _at = DateTime.utc(2026, 1, 1);

/// A feed line; people are named and identified (Ann is m1, Bob m2, this
/// member, Me, m9).
FeedMessage _feed(String action,
        {String actor = 'Ann', String? target, String reason = '', bool replayed = false}) =>
    FeedMessage(
        actor: actor,
        actorId: _ids[actor] ?? '',
        action: action,
        target: target,
        targetId: _ids[target] ?? '',
        reason: reason,
        at: _at,
        replayed: replayed);

const _ids = {'Ann': 'm1', 'Bob': 'm2', 'Me': 'm9', 'server': 'server'};

/// One row: the event (in [context]), then what it must do.
class _Row {
  final String name;
  final AppEvent event;
  final Type type;
  final NoticeContext context;
  final String? toast;
  final String? actor;
  final SfxKind? sound;
  final int readyIndex;
  final bool attention;
  /// Whether the event's own feed line goes into the activity log.
  final bool logged;
  /// The system notification's title and body, null for none.
  final (String, String)? system;
  const _Row(this.name, this.event, this.type,
      {this.context = _in,
      this.toast,
      this.actor,
      this.sound,
      this.readyIndex = 0,
      this.attention = false,
      this.logged = false,
      this.system});
}

// The contexts.
const _in = NoticeContext(self: Presence.watching);
const _away = NoticeContext(self: Presence.away);
const _awayPeople = NoticeContext(self: Presence.away, prefs: NotifyPrefs(people: true));
const _alone = NoticeContext(self: Presence.watching, alone: true);
const _background = NoticeContext(self: Presence.watching, window: WindowActivity.unfocused);
const _minimisedAway = NoticeContext(self: Presence.away, window: WindowActivity.minimised);
const _playing = NoticeContext(self: Presence.watching, playing: true);
const _chatOpen = NoticeContext(self: Presence.watching, chatOpen: true);
const _chatOpenBackground = NoticeContext(self: Presence.watching, chatOpen: true, window: WindowActivity.unfocused);
const _chatPaused = NoticeContext(self: Presence.watching, playing: true, prefs: NotifyPrefs(chat: ChatPopups.paused));
const _chatOff = NoticeContext(self: Presence.watching, window: WindowActivity.unfocused, prefs: NotifyPrefs(chat: ChatPopups.off));

/// The feed as the coordinator turns it into events: this member is m9
/// ('Me'), two members ready in the latest state.
FeedEvent _of(FeedMessage f) => FeedEvent.of(f, selfId: 'm9', readyCount: 2);

final _rows = <_Row>[
  // ---- the feed (FeedEvent.of, then noticeFor); every line is logged
  _Row('join', _of(_feed('join')), MemberJoined,
      toast: 'Ann joined', actor: 'Ann', sound: SfxKind.join, logged: true),
  _Row('leave (bye)', _of(_feed('leave', reason: 'bye')), MemberLeft,
      toast: 'Ann left', actor: 'Ann', sound: SfxKind.leave, logged: true),
  _Row('leave (grace over)', _of(_feed('leave', reason: 'grace')), MemberLeft,
      toast: 'Ann left', actor: 'Ann', sound: SfxKind.leave, logged: true),
  _Row('gone (after the delayed notice)', _of(_feed('gone')), MemberGone,
      toast: 'Ann lost connection', actor: 'Ann', logged: true),
  _Row('return', _of(_feed('return')), MemberReturned, toast: 'Ann is back', actor: 'Ann', logged: true),
  _Row('away, someone sat themselves out', _of(_feed('away')), MemberSatOut, logged: true),
  _Row('away, someone else auto sat out', _of(_feed('away', reason: 'idle')), MemberSatOut, logged: true),
  _Row('away, someone sat someone else out', _of(_feed('away', target: 'Bob')), MemberSatOut, logged: true),
  _Row('away, you sat yourself out', _of(_feed('away', actor: 'Me')), MemberSatOut, logged: true),
  _Row('away, someone sat you out', _of(_feed('away', target: 'Me')), MemberSatOut,
      toast: 'Ann sat you out', actor: 'Ann', sound: SfxKind.kick, logged: true),
  _Row('away, auto sit-out (idle)', _of(_feed('away', actor: 'Me', reason: 'idle')), MemberSatOut,
      toast: 'You sit out (idle); you are back as soon as you return', sound: SfxKind.warn, logged: true),
  _Row('away, auto sit-out (minimised)', _of(_feed('away', actor: 'Me', reason: 'minimised')), MemberSatOut,
      toast: 'You sit out (minimised); you are back as soon as you return', sound: SfxKind.warn, logged: true),
  _Row('in (back from away)', _of(_feed('in')), MemberBack, logged: true),
  _Row('a replayed join: logged only', _of(_feed('join', replayed: true)), MemberJoined, logged: true),
  _Row('a replayed chat: logged only', _of(_feed('chat', reason: 'hi', replayed: true)), ChatPosted, logged: true),
  _Row('someone with your name is not you', _of(FeedMessage(
      actor: 'Me', actorId: 'm4', action: 'away', target: 'Me', targetId: 'm9', at: _at)), MemberSatOut,
      toast: 'Me sat you out', actor: 'Me', sound: SfxKind.kick, logged: true),
  _Row('ready', _of(_feed('ready')), ReadyChanged, sound: SfxKind.ready, readyIndex: 2, logged: true),
  _Row('unready', _of(_feed('unready')), ReadyChanged, sound: SfxKind.unready, logged: true),
  _Row('force-ready', _of(_feed('force-ready')), ForcedReady, sound: SfxKind.forceReady, logged: true),
  _Row('force-unready', _of(_feed('force-unready')), ForcedReady, logged: true),
  _Row('force-play', _of(_feed('force-play')), ForcedTransport, logged: true),
  _Row('force-hold', _of(_feed('force-hold')), ForcedTransport, logged: true),
  _Row('swap', _of(_feed('swap')), MediaSwapped,
      toast: 'Ann changed media', actor: 'Ann', sound: SfxKind.swap, logged: true),
  _Row('own swap: logged only', _of(_feed('swap', actor: 'Me')), MediaSwapped, logged: true),
  _Row('seek', _of(_feed('seek')), Seeked, logged: true),
  _Row('pause', _of(_feed('pause', actor: 'server')), Paused, logged: true),
  _Row('resume', _of(_feed('resume', actor: 'server')), Resumed, logged: true),
  _Row('finished', _of(_feed('finished', actor: 'server')), Finished, logged: true),
  _Row('chat from someone', _of(_feed('chat', reason: 'hi')), ChatPosted,
      toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true),
  _Row('chat with the chat open: only its sound', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _chatOpen, sound: SfxKind.chat, logged: true),
  _Row('chat open but the window in the background: pops up and goes out', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _chatOpenBackground, toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true, system: ('Ann', 'hi')),
  _Row('own chat', _of(_feed('chat', actor: 'Me', reason: 'hi')), ChatPosted,
      toast: 'Me: hi', actor: 'Me', logged: true),
  _Row('rename', _of(_feed('rename', target: 'Annie')), MemberRenamed, logged: true),
  _Row('avatar', _of(_feed('avatar')), AvatarChanged, logged: true),
  _Row('queue-add: title, picture, who', FeedEvent.of(_feed('queue-add', target: 'Ep 6'), selfId: 'm9', queueThumb: 'h1'),
      QueueAdded, toast: 'Ann added Ep 6 to Up next', actor: 'Ann', logged: true),
  _Row('own queue-add: logged (the app said "Added")', _of(_feed('queue-add', actor: 'Me', target: 'Ep 6')),
      QueueAdded, logged: true),
  _Row('queue-remove', _of(_feed('queue-remove', target: 'Ep 6')), QueueRemoved, logged: true),
  _Row('queue-skip with a reason', _of(_feed('queue-skip', actor: 'server', target: 'Ep 6', reason: 'gone')),
      QueueSkipped, toast: 'Skipped Ep 6: gone', logged: true),
  _Row('queue-skip, no title or reason', _of(_feed('queue-skip', actor: 'server')), QueueSkipped,
      toast: 'Skipped an item', logged: true),
  _Row('fetch-fail', _of(_feed('fetch-fail', actor: 'server', reason: '404')), FetchFailed, logged: true),
  _Row('an unknown action', _of(_feed('from-the-future')), OtherFeed, logged: true),
  // ---- the session
  _Row('nudge', const Nudged('Ann'), Nudged,
      toast: 'Ann nudged you', actor: 'Ann', sound: SfxKind.nudge, attention: true),
  _Row('nudge from someone unknown', const Nudged(''), Nudged,
      toast: 'Someone nudged you', sound: SfxKind.nudge, attention: true),
  _Row('member cannot play', const MemberCantPlay('Ann', 'no codec'), MemberCantPlay,
      toast: "Ann can't play this: no codec", actor: 'Ann'),
  _Row('starting now: nothing while you watch it start', const PlaybackStarted('Frieren'), PlaybackStarted),
  _Row('the source dropped', const RelaySourceDropped('Ann'), RelaySourceDropped,
      toast: "Ann's connection dropped: playing what the server has", actor: 'Ann'),
  _Row('the source left', const RelaySourceDropped('Ann', left: true), RelaySourceDropped,
      toast: 'Ann left: playing what the server has', actor: 'Ann'),
  _Row('server restarted', const ServerRestarted(), ServerRestarted, toast: 'The server restarted; you are back in'),
  _Row('replaced', const Replaced(), Replaced, toast: 'Starsync was opened in another window'),
  _Row('server refused', const ServerRefused('Up next is full'), ServerRefused, toast: 'Up next is full'),
  _Row('slow source', const SlowSource('Passing on slower than it plays'), SlowSource,
      toast: 'Passing on slower than it plays'),
  _Row('relay started', const RelayStarted(), RelayStarted,
      toast: 'Passing the video on through the server. Keep the app open while it plays.'),
  _Row('relay failed', const RelayFailed('closed'), RelayFailed, toast: 'Cannot pass the video on: closed'),
  _Row('connection lost', const ConnectionLost(), ConnectionLost, sound: SfxKind.lost),
  _Row('connection back', const ConnectionBack(), ConnectionBack, sound: SfxKind.back),
  _Row('jellyfin, sign-in expired', const JellyfinProgressFailed(signInExpired: true), JellyfinProgressFailed,
      toast: 'Jellyfin progress not saved: sign-in expired'),
  _Row('jellyfin, unreachable', const JellyfinProgressFailed(signInExpired: false), JellyfinProgressFailed,
      toast: 'Jellyfin progress not saved: server unreachable'),
  // ---- the app
  _Row('shader message', const ShaderMessage('Shaders off'), ShaderMessage, toast: 'Shaders off'),
  _Row('added to up next', const AddedToUpNext('Ep 6'), AddedToUpNext, toast: 'Added Ep 6 to Up next'),
  _Row('action failed', const ActionFailed('No such file'), ActionFailed, toast: 'No such file'),
  _Row('schedule result', const ScheduleResult('Loaded'), ScheduleResult, toast: 'Loaded'),
  _Row('problem marked in session', const ProblemMarked(inSession: true), ProblemMarked,
      toast: 'Marked in the session log'),
  _Row('problem marked locally', const ProblemMarked(inSession: false), ProblemMarked,
      toast: "Marked in this app's log"),
  _Row('copied', const Copied('Link copied'), Copied, toast: 'Link copied'),
  _Row('copy failed', const CopyFailed(), CopyFailed, toast: "Couldn't copy"),
  _Row('update available: the band shows it', const UpdateAvailable('1.3.0'), UpdateAvailable),
];

/// The rows the context changes.
final _contextRows = <_Row>[
  // ---- sitting out (D1, P8): chat, nudges, starting now, Up next only
  _Row('away: chat pops up with its sound', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _away, toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true),
  _Row('away: a nudge', const Nudged('Ann'), Nudged,
      context: _away, toast: 'Ann nudged you', actor: 'Ann', sound: SfxKind.nudge, attention: true),
  _Row('away: starting now', const PlaybackStarted('Frieren'), PlaybackStarted,
      context: _away, toast: 'Starting now: Frieren'),
  _Row('away: an Up next add', _of(_feed('queue-add', target: 'Ep 6')), QueueAdded,
      context: _away, toast: 'Ann added Ep 6 to Up next', actor: 'Ann', logged: true),
  _Row('away: a swap', _of(_feed('swap')), MediaSwapped,
      context: _away, toast: 'Ann changed media', actor: 'Ann', sound: SfxKind.swap, logged: true),
  _Row('away: a join is logged only', _of(_feed('join')), MemberJoined, context: _away, logged: true),
  _Row('away: a leave is logged only', _of(_feed('leave', reason: 'bye')), MemberLeft, context: _away, logged: true),
  _Row('away: ready makes no sound', _of(_feed('ready')), ReadyChanged, context: _away, logged: true),
  _Row("away: someone can't play: nothing", const MemberCantPlay('Ann', 'no codec'), MemberCantPlay, context: _away),
  _Row('away, joins chosen: a join pops up', _of(_feed('join')), MemberJoined,
      context: _awayPeople, toast: 'Ann joined', actor: 'Ann', sound: SfxKind.join, logged: true),
  _Row('away: your own relay still tells you', const RelayFailed('closed'), RelayFailed,
      context: _away, toast: 'Cannot pass the video on: closed'),
  _Row('away: app notices still show', const Copied('Link copied'), Copied, context: _away, toast: 'Link copied'),
  // ---- alone (D9): no social sounds or pop-ups, app notices show
  _Row('alone: ready makes no sound', _of(_feed('ready')), ReadyChanged, context: _alone, logged: true),
  _Row('alone: a join is quiet', _of(_feed('join')), MemberJoined, context: _alone, logged: true),
  _Row('alone: own chat is quiet', _of(_feed('chat', actor: 'Me', reason: 'hi')), ChatPosted,
      context: _alone, logged: true),
  _Row('alone: app notices show', const ShaderMessage('Shaders off'), ShaderMessage,
      context: _alone, toast: 'Shaders off'),
  _Row('alone: problems show', const RelayFailed('closed'), RelayFailed,
      context: _alone, toast: 'Cannot pass the video on: closed'),
  _Row('alone: connection sounds play', const ConnectionLost(), ConnectionLost, context: _alone, sound: SfxKind.lost),
  // ---- replayed: the log only, whatever the context
  _Row('replayed chat while away in the background', _of(_feed('chat', reason: 'hi', replayed: true)), ChatPosted,
      context: _minimisedAway, logged: true),
  // ---- the window in the background: a system notification too
  _Row('background: chat goes out as a system notification', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _background, toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true, system: ('Ann', 'hi')),
  _Row('background: a nudge', const Nudged('Ann'), Nudged,
      context: _background,
      toast: 'Ann nudged you',
      actor: 'Ann',
      sound: SfxKind.nudge,
      attention: true,
      system: ('Ann', 'nudged you')),
  _Row('background: starting now', const PlaybackStarted('Frieren'), PlaybackStarted,
      context: _background, toast: 'Starting now: Frieren', system: ('Starsync', 'Starting now: Frieren')),
  _Row('background: an Up next add', _of(_feed('queue-add', target: 'Ep 6')), QueueAdded,
      context: _background,
      toast: 'Ann added Ep 6 to Up next',
      actor: 'Ann',
      logged: true,
      system: ('Ann', 'added Ep 6 to Up next')),
  _Row('background: a join pops up in the app only (not chosen)', _of(_feed('join')), MemberJoined,
      context: _background, toast: 'Ann joined', actor: 'Ann', sound: SfxKind.join, logged: true),
  _Row('background: app notices stay in the app', const Copied('Link copied'), Copied,
      context: _background, toast: 'Link copied'),
  _Row('minimised, away: chat goes out', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _minimisedAway, toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true, system: ('Ann', 'hi')),
  _Row('minimised, away: a join does not', _of(_feed('join')), MemberJoined, context: _minimisedAway, logged: true),
  _Row('background: own chat stays in the app', _of(_feed('chat', actor: 'Me', reason: 'hi')), ChatPosted,
      context: _background, toast: 'Me: hi', actor: 'Me', logged: true),
  // ---- chat pop-ups (Settings): the sound has its own switch
  _Row('playing, chat pop-ups All', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _playing, toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true),
  _Row('playing, chat pop-ups only when paused', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _chatPaused, sound: SfxKind.chat, logged: true),
  _Row('chat pop-ups off: no system notification either', _of(_feed('chat', reason: 'hi')), ChatPosted,
      context: _chatOff, sound: SfxKind.chat, logged: true),
];

void _check(_Row r) {
  expect(r.event.runtimeType, r.type, reason: 'event type');
  final n = noticeFor(r.event, r.context);
  expect(n.toast, r.toast, reason: 'toast');
  expect(n.actor, r.actor, reason: 'actor');
  expect(n.sound?.kind, r.sound, reason: 'sound');
  if (r.sound != null) expect(n.sound!.readyIndex, r.readyIndex, reason: 'ready pitch');
  expect(n.attention, r.attention, reason: 'attention');
  expect(n.system == null ? null : (n.system!.title, n.system!.body), r.system, reason: 'system notification');
  final e = r.event;
  expect(n.log, r.logged ? same((e as FeedEvent).feed) : isNull, reason: 'activity log');
}

/// Records what the Notifier sends out of the window and lets a test
/// click it.
class _FakeSystem implements SystemNotifications {
  final shown = <(String, String, String)>[];
  void Function(String payload)? _click;
  @override
  set onClick(void Function(String payload)? handler) => _click = handler;
  void click(String payload) => _click!(payload);
  @override
  Future<void> show({required String title, required String body, String tag = '', String payload = ''}) async =>
      shown.add((title, body, payload));
}

void main() {
  group('noticeFor', () {
    for (final r in _rows) {
      test(r.name, () => _check(r));
    }
  });

  group('noticeFor in context', () {
    for (final r in _contextRows) {
      test(r.name, () => _check(r));
    }
  });

  test('the queue-add toast carries the item picture', () {
    final n = noticeFor(FeedEvent.of(_feed('queue-add', target: 'Ep 6'), selfId: 'm9', queueThumb: 'h1'));
    expect(n.thumb, 'h1');
  });

  group('Notifier', () {
    test('in the background: a system notification; a click focuses the window and opens the chat', () async {
      final system = _FakeSystem();
      var focused = 0;
      final n = Notifier(system: system, focusWindow: () async => focused++, systemGap: Duration.zero);
      n.session = () => (self: Presence.watching, alone: false, playing: false);
      n.window = WindowActivity.minimised;
      n.notify(_of(_feed('chat', reason: 'hi')));
      expect(system.shown, [('Ann', 'hi', SystemNote.payloadChat)]);
      expect(n.toasts.peek().single.chat, isTrue);
      system.click(SystemNote.payloadChat);
      expect(focused, 1);
      expect(n.chatRequests.peek(), 1);
      await Future<void>.delayed(Duration.zero);
      // A click on any other one only brings the window up.
      n.notify(const PlaybackStarted('Frieren'));
      expect(system.shown.last, ('Starsync', 'Starting now: Frieren', ''));
      system.click('');
      expect(focused, 2);
      expect(n.chatRequests.peek(), 1);
      // Focused: nothing leaves the window.
      n.window = WindowActivity.focused;
      n.notify(_of(_feed('chat', reason: 'again')));
      expect(system.shown, hasLength(2));
      n.clear();
    });

    test('a burst of system notifications goes out as one, then spaced (KDE refuses many at once)', () async {
      final system = _FakeSystem();
      final n = Notifier(system: system, systemGap: const Duration(milliseconds: 200));
      n.session = () => (self: Presence.watching, alone: false, playing: false);
      n.window = WindowActivity.unfocused;
      // A swap in the background: starting now, Up next adds, chat.
      n.notify(const PlaybackStarted('Frieren'));
      n.notify(_of(_feed('queue-add', target: 'Ep 6')));
      n.notify(_of(_feed('queue-add', actor: 'Bob', target: 'Ep 7')));
      n.notify(_of(_feed('chat', reason: 'hi')));
      expect(system.shown, [('Starsync', 'Starting now: Frieren', '')], reason: 'the first goes out at once');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(system.shown, hasLength(1), reason: 'the rest waits for the gap');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Bob's add replaced Ann's (same tag, as in the notification center).
      expect(system.shown, [
        ('Starsync', 'Starting now: Frieren', ''),
        ('Starsync', 'Bob added Ep 7 to Up next\nAnn: hi', SystemNote.payloadChat),
      ]);
      // One more within the next gap waits alone and goes out as it is.
      n.notify(_of(_feed('chat', actor: 'Bob', reason: 'yo')));
      expect(system.shown, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(system.shown.last, ('Bob', 'yo', SystemNote.payloadChat));
      // Back in front: what waits is dropped.
      n.notify(_of(_feed('chat', reason: 'a')));
      n.window = WindowActivity.focused;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(system.shown, hasLength(3));
      n.clear();
    });

    test('a merged system notification keeps one title and caps its lines', () {
      final same = SystemNote.merge([
        for (final t in ['a', 'b']) SystemNote(title: 'Ann', body: t, line: 'Ann: $t'),
      ]);
      expect((same.title, same.body), ('Ann', 'a\nb'));
      final many = SystemNote.merge([
        for (var i = 0; i < 8; i++) SystemNote(title: 'P$i', body: 'x', line: 'P$i: x'),
      ]);
      expect(many.title, 'Starsync');
      expect(many.body.split('\n'), ['P0: x', 'P1: x', 'P2: x', 'P3: x', '+4 more']);
    });

    test('owns the toast timer: a toast goes after its time, a dismissed one at once', () async {
      final n = Notifier(toastLife: const Duration(milliseconds: 300));
      n.notify(const Copied('Link copied'));
      n.notify(const ShaderMessage('Shaders off'));
      expect(n.toasts.peek().map((t) => t.text), ['Link copied', 'Shaders off']);
      n.dismiss(n.toasts.peek().last.id);
      expect(n.toasts.peek().map((t) => t.text), ['Link copied']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(n.toasts.peek(), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(n.toasts.peek(), isEmpty);
    });

    test('reads the session: sitting out silences the party, alone too', () {
      final sounds = <SfxKind>[];
      final n = Notifier(sfx: _Sfx(sounds));
      var self = Presence.watching;
      var alone = false;
      n.session = () => (self: self, alone: alone, playing: false);
      n.notify(_of(_feed('join')));
      self = Presence.away;
      n.notify(_of(_feed('join', actor: 'Bob')));
      self = Presence.watching;
      alone = true;
      n.notify(_of(_feed('ready')));
      expect(n.toasts.peek().map((t) => t.text), ['Ann joined']);
      expect(sounds, [SfxKind.join]);
      expect(n.feedLog.peek(), hasLength(3), reason: 'everything is logged');
      n.clear();
    });
  });

  test('every concrete AppEvent subtype has a row', () {
    // Read from the source, so a new event fails here until it gets a row.
    final src = File('lib/src/session/app_events.dart').readAsStringSync();
    final declared = RegExp(r'^class (\w+) extends (?:FeedEvent|AppEvent)', multiLine: true)
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toSet();
    expect(declared, isNotEmpty);
    expect(_rows.map((r) => r.type.toString()).toSet(), declared);
  });
}

class _Sfx implements SfxService {
  final List<SfxKind> played;
  _Sfx(this.played);
  @override
  Future<void> play(SfxCue cue) async => played.add(cue.kind);
}
