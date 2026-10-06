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

double serverPositionAt(StateBroadcast state, DateTime now) {
  if (state.transport != 'playing') return state.position;
  return state.position + now.difference(state.serverTime).inMilliseconds / 1000.0;
}

bool seekLanded({required double ownPosition, required double target}) {
  if ((ownPosition - target).abs() > RelayConstants.driftSeekThresholdSecs) {
    return false;
  }
  return true;
}

bool localPlayAllowed(StateBroadcast state, String memberId) {
  if (memberId.isEmpty) return false;
  for (final m in state.members) {
    if (m.id == memberId) return m.inSet && m.ready;
  }
  return false;
}

/// Self is ready but out of the set and fresh again: the server's stale
/// sweep dropped it from the set during a signal gap and nothing puts it
/// back. Re-sending ready restores it without the user pressing Space.
bool shouldReassertReady(MemberView? self) =>
    self != null && self.ready && !self.inSet && !self.stale;

class StateDiff {
  static const debounceWindow = Duration(seconds: 2);

  int _lastEventId = -1;
  String _lastTransport = '';
  int _lastMediaId = -1;
  bool _slowing = false;
  DateTime? _deviatingSince;
  int _deviatingEvent = -1;

  bool get slowing => _slowing;

  List<PlayerAction> diff(StateBroadcast state, double ownPosition, DateTime now) {
    final out = <PlayerAction>[];
    final serverPos = serverPositionAt(state, now);

    if (state.mediaId != _lastMediaId && _lastMediaId != -1) {
      _lastEventId = state.eventId;
      _lastTransport = state.transport;
      _lastMediaId = state.mediaId;
      _slowing = false;
      _deviatingSince = null;
      out.add(const SeekAction(0));
      out.add(const TransportAction(false));
      out.add(const RateAction(1.0));
      return out;
    }

    if (_lastEventId == -1) {
      _lastEventId = state.eventId;
      _lastTransport = state.transport;
      _lastMediaId = state.mediaId;
      _deviatingSince = null;
      out.add(SeekAction(serverPos));
      out.add(TransportAction(state.transport == 'playing'));
      return out;
    }

    if (state.eventId != _lastEventId) {
      _lastEventId = state.eventId;
      _slowing = false;
      _deviatingSince = null;
      out.add(const RateAction(1.0));
      out.add(SeekAction(serverPos));
      if (state.transport != _lastTransport) {
        _lastTransport = state.transport;
        out.add(TransportAction(state.transport == 'playing'));
      }
      return out;
    }

    if (state.transport != _lastTransport) {
      _lastTransport = state.transport;
      _slowing = false;
      _deviatingSince = null;
      out.add(const RateAction(1.0));
      out.add(TransportAction(state.transport == 'playing'));
      out.add(SeekAction(serverPos));
      return out;
    }

    final drift = ownPosition - serverPos;
    if (_slowing) {
      if (drift.abs() < 0.1) {
        _slowing = false;
        out.add(const RateAction(1.0));
      }
      return out;
    }
    switch (correctionFor(ownPosition: ownPosition, serverPosition: serverPos)) {
      case Correction.seek:
        if (_deviatingEvent != state.eventId || _deviatingSince == null) {
          _deviatingEvent = state.eventId;
          _deviatingSince = now;
          break;
        }
        if (now.difference(_deviatingSince!).compareTo(debounceWindow) < 0) {
          break;
        }
        _deviatingSince = null;
        out.add(SeekAction(serverPos));
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
