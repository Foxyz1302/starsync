abstract class SyncRelayException implements Exception {
  final String message;
  const SyncRelayException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

class ConfigException extends SyncRelayException {
  const ConfigException(super.message);
}

class ProtocolException extends SyncRelayException {
  const ProtocolException(super.message);
}

class AuthException extends SyncRelayException {
  const AuthException(super.message);
}

class MediaException extends SyncRelayException {
  const MediaException(super.message);
}

class TunnelException extends SyncRelayException {
  const TunnelException(super.message);
}
