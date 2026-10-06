import 'package:sync_relay_core/core.dart';

sealed class PlayerAction {
  const PlayerAction();
}

class SeekAction extends PlayerAction {
  final double position;
  const SeekAction(this.position);
}

class TransportAction extends PlayerAction {
  final bool playing;
  const TransportAction(this.playing);
}

class RateAction extends PlayerAction {
  final double rate;
  const RateAction(this.rate);
}

double roomPositionAt(RoomBroadcast room, DateTime now) {
  if (room.transport != 'playing') return room.position;
  return room.position + now.difference(room.serverTime).inMilliseconds / 1000.0;
}

bool seekLanded({required double ownPosition, required double target}) {
  if ((ownPosition - target).abs() > RelayConstants.driftSeekThresholdSecs) {
    return false;
  }
  return true;
}

bool localPlayAllowed(RoomBroadcast room, String memberId) {
  if (memberId.isEmpty) return false;
  for (final m in room.members) {
    if (m.id == memberId) return m.inSet && m.ready;
  }
  return false;
}

/// Self is ready but out of the set and fresh again: the server's stale
/// sweep dropped it from the set during a signal gap and nothing puts it
/// back. Re-sending ready restores it without the user pressing Space.
bool shouldReassertReady(MemberView? self) =>
    self != null && self.ready && !self.inSet && !self.stale;

class RoomDiff {
  static const debounceWindow = Duration(seconds: 2);

  int _lastEventId = -1;
  String _lastTransport = '';
  int _lastMediaId = -1;
  bool _slowing = false;
  DateTime? _deviatingSince;
  int _deviatingEvent = -1;

  bool get slowing => _slowing;

  List<PlayerAction> diff(RoomBroadcast room, double ownPosition, DateTime now) {
    final out = <PlayerAction>[];
    final roomPos = roomPositionAt(room, now);

    if (room.mediaId != _lastMediaId && _lastMediaId != -1) {
      _lastEventId = room.eventId;
      _lastTransport = room.transport;
      _lastMediaId = room.mediaId;
      _slowing = false;
      _deviatingSince = null;
      out.add(const SeekAction(0));
      out.add(const TransportAction(false));
      out.add(const RateAction(1.0));
      return out;
    }

    if (_lastEventId == -1) {
      _lastEventId = room.eventId;
      _lastTransport = room.transport;
      _lastMediaId = room.mediaId;
      _deviatingSince = null;
      out.add(SeekAction(roomPos));
      out.add(TransportAction(room.transport == 'playing'));
      return out;
    }

    if (room.eventId != _lastEventId) {
      _lastEventId = room.eventId;
      _slowing = false;
      _deviatingSince = null;
      out.add(const RateAction(1.0));
      out.add(SeekAction(roomPos));
      if (room.transport != _lastTransport) {
        _lastTransport = room.transport;
        out.add(TransportAction(room.transport == 'playing'));
      }
      return out;
    }

    if (room.transport != _lastTransport) {
      _lastTransport = room.transport;
      _slowing = false;
      _deviatingSince = null;
      out.add(const RateAction(1.0));
      out.add(TransportAction(room.transport == 'playing'));
      out.add(SeekAction(roomPos));
      return out;
    }

    final drift = ownPosition - roomPos;
    if (_slowing) {
      if (drift.abs() < 0.1) {
        _slowing = false;
        out.add(const RateAction(1.0));
      }
      return out;
    }
    switch (correctionFor(ownPosition: ownPosition, roomPosition: roomPos)) {
      case Correction.seek:
        if (_deviatingEvent != room.eventId || _deviatingSince == null) {
          _deviatingEvent = room.eventId;
          _deviatingSince = now;
          break;
        }
        if (now.difference(_deviatingSince!).compareTo(debounceWindow) < 0) {
          break;
        }
        _deviatingSince = null;
        out.add(SeekAction(roomPos));
      case Correction.slowDown:
        _deviatingSince = null;
        _slowing = true;
        out.add(const RateAction(RelayConstants.slowDownRate));
      case Correction.none:
        _deviatingSince = null;
        break;
    }
    return out;
  }

  void reset() {
    _lastEventId = -1;
    _lastTransport = '';
    _lastMediaId = -1;
    _slowing = false;
    _deviatingSince = null;
    _deviatingEvent = -1;
  }
}
