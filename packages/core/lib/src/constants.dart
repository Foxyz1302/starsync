abstract class RelayConstants {
  static const int protoVersion = 4;

  static const int chunkBytes = 256 * 1024;
  static const int creditWindowChunks = 8;
  static const int maxConcurrentOpen = 16;

  static const int seekDebounceMs = 300;
  static const double driftSeekThresholdSecs = 5.0;
  static const double slowDownThresholdSecs = 1.5;
  static const double slowDownRate = 0.95;
  static const double minBufferSecs = 4.0;
  static const double resumeHysteresisSecs = 4.0;

  static const int stateHeartbeatSecs = 1;
  static const int pingIntervalSecs = 5;

  static const int maxAvatarBytes = 64 * 1024;
  static const int maxNameLength = 32;
  static const int maxChatLength = 500;
}
