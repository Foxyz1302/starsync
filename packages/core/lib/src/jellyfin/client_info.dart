/// Identifies this app to Jellyfin. Always send all four fields: on 10.11
/// an unauthenticated request (Quick Connect, sign-in) whose
/// `Authorization: MediaBrowser ...` header lacks any of them (e.g. no
/// Version) is rejected with 400 and no body. Token-carrying requests are
/// more lenient, but progress reports are attributed by these fields.
///
/// [deviceId] must be stable per install (persist a random id once).
/// Jellyfin keys devices, sessions and tokens by it: signing the same user
/// in again with the same DeviceId reuses that device entry instead of
/// piling up devices on the user's dashboard.
class JellyfinClientInfo {
  /// App name shown in Jellyfin's dashboard ("Watch Together").
  final String client;
  /// Device name shown in the dashboard (e.g. the hostname).
  final String device;
  final String deviceId;
  final String version;
  const JellyfinClientInfo({
    required this.client,
    required this.device,
    required this.deviceId,
    required this.version,
  });

  /// The `Authorization` header value. Values are percent-encoded (the
  /// server decodes them), so names with quotes, commas or non-ASCII
  /// characters are safe.
  String authorizationHeader([String? token]) {
    final parts = <String>[
      'Client="${Uri.encodeComponent(client)}"',
      'Device="${Uri.encodeComponent(device)}"',
      'DeviceId="${Uri.encodeComponent(deviceId)}"',
      'Version="${Uri.encodeComponent(version)}"',
      if (token != null && token.isNotEmpty) 'Token="${Uri.encodeComponent(token)}"',
    ];
    return 'MediaBrowser ${parts.join(', ')}';
  }
}
