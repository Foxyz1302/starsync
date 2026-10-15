// restructure: rewrite in step 1 (Connection + Identity + Presence): the
// feed rows follow the new feed actions one-to-one (away/in/gone/return);
// step 2 (Status + Notifier): every row, when noticeFor takes a context.
//
// The Notifier policy as a table: one row per AppEvent subtype, what
// noticeFor makes of it (toast text and actor, sound, attention, activity-log
// line). A policy change edits a row here on purpose.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show FeedMessage;
import 'package:watch_together/src/session/notifier.dart';
import 'package:watch_together/src/sfx/sfx.dart';

final _at = DateTime.utc(2026, 1, 1);

FeedMessage _feed(String action, {String actor = 'Ann', String? target, String reason = ''}) =>
    FeedMessage(actor: actor, action: action, target: target, reason: reason, at: _at);

/// One row: the event, then what it must do.
class _Row {
  final String name;
  final AppEvent event;
  final Type type;
  final String? toast;
  final String? actor;
  final SfxKind? sound;
  final int readyIndex;
  final bool attention;
  /// Whether the event's own feed line goes into the activity log.
  final bool logged;
  const _Row(this.name, this.event, this.type,
      {this.toast, this.actor, this.sound, this.readyIndex = 0, this.attention = false, this.logged = false});
}

/// The feed as the coordinator turns it into events: this member is 'Me',
/// two members ready in the latest state.
FeedEvent _of(FeedMessage f) => FeedEvent.of(f, selfName: 'Me', readyCount: 2);

final _rows = <_Row>[
  // ---- the feed (FeedEvent.of, then noticeFor); every line is logged
  _Row('join', _of(_feed('join')), MemberJoined,
      toast: 'Ann joined', actor: 'Ann', sound: SfxKind.join, logged: true),
  _Row('leave', _of(_feed('leave')), MemberLeft,
      toast: 'Ann left', actor: 'Ann', sound: SfxKind.leave, logged: true),
  _Row('stale', _of(_feed('stale')), MemberStale, logged: true),
  _Row('out, someone else sat out', _of(_feed('out', target: 'Bob')), MemberSatOut, logged: true),
  _Row('out, sat yourself out', _of(_feed('out', actor: 'Me', target: 'Me')), MemberSatOut, logged: true),
  _Row('out, someone sat you out', _of(_feed('out', target: 'Me')), MemberSatOut,
      toast: 'Ann sat you out', actor: 'Ann', sound: SfxKind.kick, logged: true),
  _Row('back', _of(_feed('back')), MemberBack, logged: true),
  _Row('ready', _of(_feed('ready')), ReadyChanged, sound: SfxKind.ready, readyIndex: 2, logged: true),
  _Row('unready', _of(_feed('unready')), ReadyChanged, sound: SfxKind.unready, logged: true),
  _Row('force-ready', _of(_feed('force-ready')), ForcedReady, sound: SfxKind.forceReady, logged: true),
  _Row('force-unready', _of(_feed('force-unready')), ForcedReady, logged: true),
  _Row('force-play', _of(_feed('force-play')), ForcedTransport, logged: true),
  _Row('force-hold', _of(_feed('force-hold')), ForcedTransport, logged: true),
  _Row('swap', _of(_feed('swap')), MediaSwapped,
      toast: 'Ann changed media', actor: 'Ann', sound: SfxKind.swap, logged: true),
  _Row('seek', _of(_feed('seek')), Seeked, logged: true),
  _Row('pause', _of(_feed('pause', actor: 'server')), Paused, logged: true),
  _Row('resume', _of(_feed('resume', actor: 'server')), Resumed, logged: true),
  _Row('finished', _of(_feed('finished', actor: 'server')), Finished, logged: true),
  _Row('chat from someone', _of(_feed('chat', reason: 'hi')), ChatPosted,
      toast: 'Ann: hi', actor: 'Ann', sound: SfxKind.chat, logged: true),
  _Row('own chat', _of(_feed('chat', actor: 'Me', reason: 'hi')), ChatPosted,
      toast: 'Me: hi', actor: 'Me', logged: true),
  _Row('rename', _of(_feed('rename', target: 'Annie')), MemberRenamed, logged: true),
  _Row('avatar', _of(_feed('avatar')), AvatarChanged, logged: true),
  _Row('queue-add', _of(_feed('queue-add', target: 'Ep 6')), QueueAdded, logged: true),
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
  _Row('slow source', const SlowSource('Passing on slower than it plays'), SlowSource,
      toast: 'Passing on slower than it plays'),
  _Row('relay started', const RelayStarted(), RelayStarted,
      toast: 'Passing the video on through the server. Keep the app open while it plays.'),
  _Row('relay failed', const RelayFailed('closed'), RelayFailed, toast: 'Cannot pass the video on: closed'),
  _Row('idle, unready', const IdleWarning(sitsOut: false), IdleWarning,
      toast: 'idle — auto-unready in 2 min unless you press Space', sound: SfxKind.warn),
  _Row('idle, sits out', const IdleWarning(sitsOut: true), IdleWarning,
      toast: 'idle — sitting out in 2 min unless you press Space', sound: SfxKind.warn),
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
  _Row('update available', const UpdateAvailable('1.3.0'), UpdateAvailable),
];

void main() {
  group('noticeFor', () {
    for (final r in _rows) {
      test(r.name, () {
        expect(r.event.runtimeType, r.type, reason: 'event type');
        final n = noticeFor(r.event);
        expect(n.toast, r.toast, reason: 'toast');
        expect(n.actor, r.actor, reason: 'actor');
        expect(n.sound?.kind, r.sound, reason: 'sound');
        if (r.sound != null) expect(n.sound!.readyIndex, r.readyIndex, reason: 'ready pitch');
        expect(n.attention, r.attention, reason: 'attention');
        final e = r.event;
        expect(n.log, r.logged ? same((e as FeedEvent).feed) : isNull, reason: 'activity log');
      });
    }
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
