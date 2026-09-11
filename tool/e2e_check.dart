import 'dart:io';

import 'package:sync_relay_core/core.dart';

int _failures = 0;

void check(String name, bool ok, [String detail = '']) {
  // ignore: avoid_print
  print('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' ($detail)'}');
  if (!ok) _failures++;
}

class FakeViewer {
  final RoomEngine engine;
  final String token;
  double ownPosition;
  double buffered;
  final double lagSecs;
  int seenEventId = 0;

  FakeViewer(this.engine, this.token,
      {this.ownPosition = 0, this.buffered = 6.0, this.lagSecs = 0});

  void tick() {
    seenEventId = engine.eventId;
    final edge = engine.positionAt();
    if ((ownPosition - edge).abs() > 0.5) {
      ownPosition = edge - lagSecs;
      if (ownPosition < 0) ownPosition = 0;
    } else {
      ownPosition = edge - lagSecs;
      if (ownPosition < 0) ownPosition = 0;
    }
    engine.applyReport(token, ownPosition, buffered, seenEventId);
  }
}

Future<void> main(List<String> args) async {
  var simTime = DateTime.utc(2026, 1, 1);
  final engine = RoomEngine(clock: () => simTime);
  engine.media = const HelloMedia(name: 'Movie.mkv', size: 4000000000, duration: 7200.0);

  void step([int seconds = 1]) => simTime = simTime.add(Duration(seconds: seconds));

  engine.applyJoin('a', 'alice', '');
  engine.applyJoin('b', 'bob', '');
  engine.applyJoin('c', 'cara', '');
  for (final t in ['a', 'b', 'c']) {
    engine.applyReady(t, true);
    engine.applyReport(t, 0, 6.0, engine.eventId);
  }
  check('room playing after all ready+buffered', engine.transport == Transport.playing);

  final alice = FakeViewer(engine, 'a');
  final bob = FakeViewer(engine, 'b');
  final cara = FakeViewer(engine, 'c', lagSecs: 8.0);
  var viewers = [alice, bob, cara];

  for (var s = 0; s < 3600; s++) {
    step();
    for (final v in viewers) {
      v.tick();
    }
  }
  final edge1h = engine.positionAt();
  check('1h in, edge advanced ~3600s', (edge1h - 3600).abs() < 2.0, 'edge=$edge1h');
  check('lagging cara never dragged clock', (engine.positionAt() - 3600).abs() < 2.0,
      'edge=${engine.positionAt()}');

  final eidBeforeSeek = engine.eventId;
  engine.applySeek('a', edge1h + 600);
  check('seek jumps edge once', (engine.positionAt() - (edge1h + 600)).abs() < 0.01);
  check('seek bumps eventId', engine.eventId == eidBeforeSeek + 1);
  engine.applyReport('c', edge1h - 8.0, 6.0, eidBeforeSeek);
  check('stale-event report causes no ping-pong',
      (engine.positionAt() - (edge1h + 600)).abs() < 0.5, 'edge=${engine.positionAt()}');

  for (var s = 0; s < 1800; s++) {
    step();
    for (final v in viewers) {
      v.tick();
    }
  }

  engine.applyJoin('d', 'dan', '');
  check('mid-play join does not halt room', engine.transport == Transport.playing);
  final dan = FakeViewer(engine, 'd');
  dan.ownPosition = engine.positionAt();
  dan.tick();
  engine.applyReady('d', true);
  engine.applyReport('d', dan.ownPosition, 6.0, engine.eventId);
  viewers.add(dan);
  check('late joiner lands in set + in sync',
      engine.members['d']!.inSet && (dan.ownPosition - engine.positionAt()).abs() < 1.0);

  for (var s = 0; s < 600; s++) {
    step();
    for (final v in viewers) {
      v.tick();
    }
  }
  engine.applyReady('b', false);
  final frozen = engine.positionAt();
  check('unready pauses room', engine.transport == Transport.held);
  for (var s = 0; s < 30; s++) {
    step();
    engine.applyReport('a', frozen, 6.0, engine.eventId);
    engine.applyReport('c', frozen - 8.0, 6.0, engine.eventId);
    engine.applyReport('d', frozen, 6.0, engine.eventId);
  }
  check('held edge frozen for 30s', (engine.positionAt() - frozen).abs() < 0.01);
  engine.applyReady('b', true);
  for (final v in viewers) {
    engine.applyReport(v.token, frozen, 6.0, engine.eventId);
  }
  check('unpause resumes', engine.transport == Transport.playing);
  check('resume aligned within RTT tolerance', (engine.positionAt() - frozen).abs() < 1.0,
      'edge=${engine.positionAt()} frozen=$frozen');

  for (var i = 0; i < 20; i++) {
    engine.applyReady('c', false);
    engine.applyReady('c', true);
    engine.applyReport('c', engine.positionAt(), 6.0, engine.eventId);
  }
  check('post-flap room converges to playing', engine.transport == Transport.playing);

  engine.applySwap('a', const HelloMedia(name: 'Ep02.mkv', size: 100, duration: 1200.0));
  check('swap holds + resets edge', engine.transport == Transport.held && engine.positionAt() == 0);
  check('swap clears sets', engine.members.values.every((m) => !m.inSet && !m.ready));

  // ignore: avoid_print
  print(_failures == 0 ? 'E2E ALL PASS' : 'E2E $_failures FAILURES');
  exitCode = _failures == 0 ? 0 : 1;
}
