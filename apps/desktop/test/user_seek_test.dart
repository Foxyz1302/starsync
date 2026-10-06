import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/sync/user_seek.dart';

StateBroadcast _state({int eventId = 1, String? seekBy, int? seekSeq}) =>
    StateBroadcast(
      eventId: eventId,
      transport: 'playing',
      position: 0,
      serverTime: DateTime.utc(2026),
      mediaId: 1,
      members: const [],
      seekBy: seekBy,
      seekSeq: seekSeq,
    );

void main() {
  final t0 = DateTime.utc(2026, 1, 1);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('a drag is one seek, sent after the user stops', () {
    final g = UserSeekGate(debounce: const Duration(milliseconds: 300));
    for (var i = 0; i < 100; i++) {
      g.request(20.0 + i, at(i * 30));
      expect(g.takeSettled(at(i * 30 + 10)), isNull, reason: 'still dragging');
      expect(g.holdsPlayer(at(i * 30 + 10)), isTrue);
    }
    final sent = g.takeSettled(at(99 * 30 + 300));
    expect(sent!.position, 119.0);
    expect(sent.seq, 1);
    expect(g.takeSettled(at(99 * 30 + 600)), isNull, reason: 'sent once');
  });

  test('holds until the echo of the last seek, then releases', () {
    final g = UserSeekGate(debounce: const Duration(milliseconds: 300));
    g.request(50, at(0));
    final first = g.takeSettled(at(300))!;
    g.request(60, at(400));
    final second = g.takeSettled(at(700))!;
    expect(second.seq, first.seq + 1);
    // Echo of the older seek: ours, but the hold stays.
    final old = _state(eventId: 2, seekBy: 'm1', seekSeq: first.seq);
    expect(g.isOwnEcho(old, 'm1'), isTrue);
    g.observe(old, 'm1');
    expect(g.holdsPlayer(at(800)), isTrue);
    g.observe(_state(eventId: 3, seekBy: 'm1', seekSeq: second.seq), 'm1');
    expect(g.holdsPlayer(at(900)), isFalse);
    expect(g.target, isNull);
  });

  test('someone else\'s seek is not ours', () {
    final g = UserSeekGate();
    g.request(5, at(0));
    g.takeSettled(at(1000));
    expect(g.isOwnEcho(_state(seekBy: 'm2', seekSeq: 1), 'm1'), isFalse);
    expect(g.isOwnEcho(_state(), 'm1'), isFalse);
  });

  test('a lost echo stops holding the player after the timeout', () {
    final g = UserSeekGate(
        debounce: const Duration(milliseconds: 300),
        echoTimeout: const Duration(seconds: 3));
    g.request(5, at(0));
    g.takeSettled(at(300));
    expect(g.holdsPlayer(at(3000)), isTrue);
    expect(g.holdsPlayer(at(3400)), isFalse);
  });
}
