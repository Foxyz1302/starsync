import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/sync/state_diff.dart';

StateBroadcast _state({
  int eventId = 0,
  String transport = 'held',
  double position = 10.0,
  int mediaId = 1,
}) {
  final now = DateTime.now().toUtc();
  return StateBroadcast(
    eventId: eventId,
    transport: transport,
    position: position,
    serverTime: now,
    mediaId: mediaId,
    members: const [],
  );
}

StateBroadcast _stateWithMembers(List<MemberView> members,
    {String transport = 'playing'}) {
  final now = DateTime.now().toUtc();
  return StateBroadcast(
    eventId: 3,
    transport: transport,
    position: 10.0,
    serverTime: now,
    mediaId: 1,
    members: members,
  );
}

void main() {
  test('initial diff seeks to server edge and sets transport', () {
    final diff = StateDiff();
    final actions = diff.diff(_state(), 0, DateTime.now().toUtc());
    expect(actions.whereType<SeekAction>().single.position, closeTo(10.0, 1.0));
    expect(actions.whereType<TransportAction>().single.playing, isFalse);
  });

  test('same event small drift does nothing', () {
    final diff = StateDiff();
    final now = DateTime.now().toUtc();
    diff.diff(_state(), 0, now);
    final actions = diff.diff(_state(), 10.5, now);
    expect(actions, isEmpty);
  });

  test('ahead drift latches slowdown, resets inside 0.1', () {
    final diff = StateDiff();
    final now = DateTime.now().toUtc();
    diff.diff(_state(), 0, now);
    var actions = diff.diff(_state(), 13.0, now);
    expect(actions.whereType<RateAction>().single.rate, 0.95);
    actions = diff.diff(_state(), 12.0, now);
    expect(actions, isEmpty);
    actions = diff.diff(_state(), 10.05, now);
    expect(actions.whereType<RateAction>().single.rate, 1.0);
  });

  test('eventId jump seeks and resets rate', () {
    final diff = StateDiff();
    final now = DateTime.now().toUtc();
    diff.diff(_state(), 0, now);
    diff.diff(_state(), 13.0, now);
    final actions =
        diff.diff(_state(eventId: 1, position: 90.0), 13.0, now);
    expect(actions.whereType<SeekAction>().single.position, closeTo(90.0, 1.0));
    expect(actions.whereType<RateAction>().single.rate, 1.0);
  });

  test('media swap seeks zero and pauses', () {
    final diff = StateDiff();
    final now = DateTime.now().toUtc();
    diff.diff(_state(transport: 'playing'), 10.0, now);
    final actions = diff.diff(
        _state(eventId: 2, transport: 'held', position: 0, mediaId: 2),
        50.0,
        now);
    expect(actions.whereType<SeekAction>().single.position, 0);
    expect(actions.whereType<TransportAction>().single.playing, isFalse);
  });

  group('seek debounce while playing', () {
    StateBroadcast playing({int eventId = 5, double position = 100.0}) => _state(
        eventId: eventId, transport: 'playing', position: position);

    test('fresh big drift is swallowed first, seeks after window', () {
      final diff = StateDiff();
      final t0 = DateTime.now().toUtc();
      diff.diff(playing(), 100.0, t0);
      var actions = diff.diff(playing(), 120.0, t0);
      expect(actions.whereType<SeekAction>(), isEmpty,
          reason: 'user scrub must not be yanked back before detector runs');
      actions = diff.diff(
          playing(), 120.0, t0.add(StateDiff.debounceWindow + const Duration(milliseconds: 100)));
      expect(actions.whereType<SeekAction>().single.position,
          closeTo(102.0, 3.0),
          reason: 'genuine drift still converges after the window');
    });

    test('new eventId seeks immediately (echo of promoted seek)', () {
      final diff = StateDiff();
      final t0 = DateTime.now().toUtc();
      diff.diff(playing(), 100.0, t0);
      diff.diff(playing(), 120.0, t0);
      final actions = diff.diff(playing(eventId: 6, position: 120.0), 120.0, t0);
      expect(actions.whereType<SeekAction>().single.position,
          closeTo(120.0, 2.0));
    });

    test('held transport debounces the same way (detector promotes)', () {
      final diff = StateDiff();
      final t0 = DateTime.now().toUtc();
      diff.diff(_state(), 10.0, t0);
      var actions = diff.diff(_state(), 60.0, t0);
      expect(actions.whereType<SeekAction>(), isEmpty);
      actions = diff.diff(_state(), 60.0,
          t0.add(StateDiff.debounceWindow + const Duration(milliseconds: 100)));
      expect(actions.whereType<SeekAction>().single.position,
          closeTo(10.0, 3.0));
    });
  });

  group('local play gate', () {
    const ready = MemberView(
        id: 'm1',
        name: 'a',
        ready: true,
        inSet: true,
        buffered: 9,
        stale: false);
    const catchingUp = MemberView(
        id: 'm2',
        name: 'b',
        ready: false,
        inSet: false,
        buffered: 0,
        stale: false);
    const unreadyInSet = MemberView(
        id: 'm3',
        name: 'c',
        ready: false,
        inSet: true,
        buffered: 9,
        stale: false);

    test('only in-set ready members may follow transport to playing', () {
      final state = _stateWithMembers([ready, catchingUp, unreadyInSet]);
      expect(localPlayAllowed(state, 'm1'), isTrue);
      expect(localPlayAllowed(state, 'm2'), isFalse);
      expect(localPlayAllowed(state, 'm3'), isFalse);
      expect(localPlayAllowed(state, 'nope'), isFalse);
      expect(localPlayAllowed(state, ''), isFalse);
    });
  });
}
