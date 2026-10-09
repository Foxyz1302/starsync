abstract class RelayConstants {
  static const int protoVersion = 11;

  // Relay (`/r/...`): a member's bytes through the server's buffer.
  static const int relaySliceBytes = 1 << 20;
  static const int relayFrameBytes = 64 * 1024;
  /// Defaults for the buffer; they mirror a viewer's mpv buffer (150 s /
  /// 256 MiB ahead, 64 MiB back), so whatever a viewer may seek to soon is
  /// already on the server.
  static const int relayAheadBytes = 256 << 20;
  static const int relayBackBytes = 64 << 20;
  /// Kept regardless of position: containers keep their index at the start
  /// or the end, and players read both on open and on seeks.
  static const int relayPinBytes = 2 << 20;
  /// A relayed media of several tracks splits the buffer by bitrate; no
  /// track gets less than this ahead or behind.
  static const int relayTrackFloorBytes = 8 << 20;
  /// Upstream GETs are split into ranges of at most this (yt-dlp's
  /// `http_chunk_size` when it gives one): YouTube throttles longer ones to
  /// about twice the bitrate.
  static const int relayUpstreamChunkBytes = 10 << 20;
  static const int relayMinWindowBytes = 256 * 1024;
  static const int relayMaxWindowBytes = 8 << 20;
  /// A viewer request waits this long for its bytes (source away) before
  /// the server gives up on it.
  static const int relayWaitSecs = 60;

  static const int seekDebounceMs = 300;
  static const double driftSeekThresholdSecs = 5.0;
  static const double slowDownThresholdSecs = 1.5;
  static const double slowDownRate = 0.95;
  static const double minBufferSecs = 4.0;
  /// Near the end the buffer requirement is what is left minus this, so a
  /// client slightly ahead of the clock (or whose last packet ends a bit
  /// early) still passes.
  static const double endSlackSecs = 2.0;
  static const double resumeHysteresisSecs = 4.0;

  static const int stateHeartbeatSecs = 1;
  static const int pingIntervalSecs = 5;

  // Base64-char count of the avatar string, enforced at hello and
  // profile. 256 KiB leaves wide headroom over any 128x128 pipeline PNG
  // (raw bitmap <= 64 KiB, worst-case base64 ~95 KiB chars) — deliberate
  // over-size for private-server use. PNG keeps transparency; JPEG did
  // not. Only the hash rides in `state`; the bytes are fetched once.
  static const int maxAvatarBytes = 256 * 1024;
  /// Decoded-byte caps of the current media's art (`art` message).
  static const int maxPosterBytes = 256 * 1024;
  static const int maxBannerBytes = 768 * 1024;
  static const int maxNameLength = 32;
  static const int maxChatLength = 500;
}
