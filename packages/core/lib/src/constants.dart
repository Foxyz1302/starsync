abstract class RelayConstants {
  static const int protoVersion = 6;

  static const int chunkBytes = 256 * 1024;
  static const int creditWindowChunks = 8;
  static const int maxConcurrentOpen = 16;

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

  // Base64-char count of the avatar string, enforced at hello. 256 KiB
  // leaves wide headroom over any 128x128 pipeline PNG (raw bitmap
  // <= 64 KiB, worst-case base64 ~95 KiB chars) — deliberate over-size
  // for private-server use. PNG keeps transparency; JPEG did not.
  // Trade: avatars ride in the 1 Hz state broadcast, so worst-case host
  // uplink scales with this cap. Follow-up (not now): send avatar bytes
  // once, reference by hash afterwards.
  static const int maxAvatarBytes = 256 * 1024;
  static const int maxNameLength = 32;
  static const int maxChatLength = 500;
}
